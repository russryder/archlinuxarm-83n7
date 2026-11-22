// SPDX-License-Identifier: GPL-2.0
/*
 * NVIDIA N1X (MediaTek MT8991 camera subsystem) SENINF: CSI-2 receiver.
 *
 * Stage 0 skeleton. It does NOT touch SENINF registers: the block sits in a
 * camera power domain (MTCMOS) and clock tree that Linux cannot control yet
 * (power_wrap has \_SB.ISP1 as CTRL_NONE and no entry for \_SB.SENI), and on
 * MediaTek SoCs an access to an unpowered/unclocked block can hang the bus.
 *
 * What it does:
 *   - binds ACPI NVDA2820 (\_SB.SENI);
 *   - decodes the _DSM "MEMS" table (UUID 7b139f92-..., fn 2), which names
 *     the _CRS resources, using the same names as MediaTek's ISP8 driver
 *     (mtkcam/camsys/isp8/cam/mtk_cam-seninf-drv.c, mtk_csi_phy_3_0);
 *   - registers a media device and a SENINF subdev (pad 0 sink, pad 1 source);
 *   - acts as the v4l2-async notifier for the sensors on its fwnode graph
 *     (supplied by yoga9n-cam.ko as a software node), links them and creates
 *     the subdev device nodes.
 *
 * Register programming (PHY 3.0, CSI-2 MAC, outmux -> CAMSV) comes in later
 * stages, once camera power/clock control exists.
 */

#include <linux/acpi.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <media/media-device.h>
#include <media/v4l2-async.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-subdev.h>

#define SENINF_PAD_SINK		0
#define SENINF_PAD_SRC		1
#define SENINF_NUM_PADS		2

/* \_SB.SENI._DSM */
static const guid_t seninf_dsm_guid =
	GUID_INIT(0x7b139f92, 0x69c7, 0x4dbf,
		  0xbd, 0xf4, 0x9c, 0x5a, 0xdc, 0xab, 0xbd, 0x07);
#define SENINF_DSM_REV		1
#define SENINF_DSM_FN_SOC	1	/* IOMV: { "mt8991" } */
#define SENINF_DSM_FN_MEMS	2	/* { name, first _CRS index, count } x N */

struct n1x_seninf {
	struct device *dev;
	struct media_device mdev;
	struct v4l2_device v4l2_dev;
	struct v4l2_subdev sd;
	struct media_pad pads[SENINF_NUM_PADS];
	struct v4l2_async_notifier notifier;
	unsigned int num_sensors;
};

static inline struct n1x_seninf *nf_to_seninf(struct v4l2_async_notifier *n)
{
	return container_of(n, struct n1x_seninf, notifier);
}

/* ------------------------------------------------------------------------
 * ACPI description
 */

static void n1x_seninf_dump_mems(struct n1x_seninf *s)
{
	acpi_handle handle = ACPI_HANDLE(s->dev);
	union acpi_object *pkg, *soc;
	unsigned int i, nres = 0;
	struct resource *r;

	while ((r = platform_get_resource(to_platform_device(s->dev),
					  IORESOURCE_MEM, nres)))
		nres++;
	dev_info(s->dev, "%u MMIO resources, %d IRQs\n", nres,
		 platform_irq_count(to_platform_device(s->dev)));

	soc = acpi_evaluate_dsm_typed(handle, &seninf_dsm_guid, SENINF_DSM_REV,
				      SENINF_DSM_FN_SOC, NULL,
				      ACPI_TYPE_PACKAGE);
	if (soc) {
		if (soc->package.count &&
		    soc->package.elements[0].type == ACPI_TYPE_STRING)
			dev_info(s->dev, "SoC: %s\n",
				 soc->package.elements[0].string.pointer);
		ACPI_FREE(soc);
	}

	pkg = acpi_evaluate_dsm_typed(handle, &seninf_dsm_guid, SENINF_DSM_REV,
				      SENINF_DSM_FN_MEMS, NULL,
				      ACPI_TYPE_PACKAGE);
	if (!pkg) {
		dev_warn(s->dev, "no MEMS table in _DSM\n");
		return;
	}

	for (i = 0; i + 2 < pkg->package.count; i += 3) {
		union acpi_object *name = &pkg->package.elements[i];
		union acpi_object *first = &pkg->package.elements[i + 1];
		union acpi_object *count = &pkg->package.elements[i + 2];
		struct resource *res;

		if (name->type != ACPI_TYPE_STRING ||
		    first->type != ACPI_TYPE_INTEGER ||
		    count->type != ACPI_TYPE_INTEGER)
			break;

		/* _CRS indices: MMIO first, then the IRQs. */
		res = platform_get_resource(to_platform_device(s->dev),
					    IORESOURCE_MEM,
					    first->integer.value);
		if (res)
			dev_info(s->dev, "  %-24s res %2llu x%-2llu @ %pa\n",
				 name->string.pointer, first->integer.value,
				 count->integer.value, &res->start);
		else
			dev_info(s->dev, "  %-24s res %2llu x%-2llu (irq %d)\n",
				 name->string.pointer, first->integer.value,
				 count->integer.value,
				 platform_get_irq_optional(to_platform_device(s->dev),
							   first->integer.value - nres));
	}
	ACPI_FREE(pkg);
}

/* ------------------------------------------------------------------------
 * Subdev: no hardware access yet, only topology.
 */

static const struct media_entity_operations n1x_seninf_entity_ops = {
	.link_validate = v4l2_subdev_link_validate,
};

static const struct v4l2_subdev_ops n1x_seninf_subdev_ops = {
};

/* ------------------------------------------------------------------------
 * Async notifier
 */

static int n1x_seninf_bound(struct v4l2_async_notifier *n,
			    struct v4l2_subdev *sensor,
			    struct v4l2_async_connection *asc)
{
	struct n1x_seninf *s = nf_to_seninf(n);
	int pad, ret;

	pad = media_entity_get_fwnode_pad(&sensor->entity, asc->match.fwnode,
					  MEDIA_PAD_FL_SOURCE);
	if (pad < 0)
		pad = 0;	/* single-pad sensors such as ov08x40 */

	ret = media_create_pad_link(&sensor->entity, pad,
				    &s->sd.entity, SENINF_PAD_SINK,
				    MEDIA_LNK_FL_ENABLED |
				    MEDIA_LNK_FL_IMMUTABLE);
	if (ret) {
		dev_err(s->dev, "link %s -> seninf: %d\n", sensor->name, ret);
		return ret;
	}

	s->num_sensors++;
	dev_info(s->dev, "bound sensor %s (pad %d)\n", sensor->name, pad);
	return 0;
}

static void n1x_seninf_unbind(struct v4l2_async_notifier *n,
			      struct v4l2_subdev *sensor,
			      struct v4l2_async_connection *asc)
{
	struct n1x_seninf *s = nf_to_seninf(n);

	s->num_sensors--;
	dev_info(s->dev, "unbound sensor %s\n", sensor->name);
}

static int n1x_seninf_complete(struct v4l2_async_notifier *n)
{
	struct n1x_seninf *s = nf_to_seninf(n);
	int ret;

	ret = v4l2_device_register_subdev_nodes(&s->v4l2_dev);
	if (ret)
		return ret;

	dev_info(s->dev, "%u sensor(s) bound, subdev nodes registered\n",
		 s->num_sensors);
	return 0;
}

static const struct v4l2_async_notifier_operations n1x_seninf_nf_ops = {
	.bound = n1x_seninf_bound,
	.unbind = n1x_seninf_unbind,
	.complete = n1x_seninf_complete,
};

static int n1x_seninf_parse_graph(struct n1x_seninf *s)
{
	struct fwnode_handle *ep;
	unsigned int n = 0;

	fwnode_graph_for_each_endpoint(dev_fwnode(s->dev), ep) {
		struct v4l2_fwnode_endpoint vep = {
			.bus_type = V4L2_MBUS_CSI2_DPHY,
		};
		struct v4l2_async_connection *asc;
		int ret;

		ret = v4l2_fwnode_endpoint_parse(ep, &vep);
		if (ret) {
			dev_warn(s->dev, "endpoint parse: %d\n", ret);
			continue;
		}

		asc = v4l2_async_nf_add_fwnode_remote(&s->notifier, ep,
						      struct v4l2_async_connection);
		if (IS_ERR(asc)) {
			dev_warn(s->dev, "add remote: %ld\n", PTR_ERR(asc));
			continue;
		}

		dev_info(s->dev, "port %u: CSI-2 D-PHY, %u data lanes\n",
			 vep.base.port, vep.bus.mipi_csi2.num_data_lanes);
		n++;
	}

	return n ? 0 : -ENODEV;
}

/* ------------------------------------------------------------------------
 * Probe / remove
 */

static int n1x_seninf_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct n1x_seninf *s;
	int ret;

	s = devm_kzalloc(dev, sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;
	s->dev = dev;
	platform_set_drvdata(pdev, s);

	n1x_seninf_dump_mems(s);

	s->mdev.dev = dev;
	strscpy(s->mdev.model, "n1x-seninf", sizeof(s->mdev.model));
	media_device_init(&s->mdev);
	s->v4l2_dev.mdev = &s->mdev;

	ret = v4l2_device_register(dev, &s->v4l2_dev);
	if (ret)
		goto err_mdev;

	v4l2_subdev_init(&s->sd, &n1x_seninf_subdev_ops);
	s->sd.owner = THIS_MODULE;
	s->sd.dev = dev;
	s->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	s->sd.entity.function = MEDIA_ENT_F_VID_IF_BRIDGE;
	s->sd.entity.ops = &n1x_seninf_entity_ops;
	snprintf(s->sd.name, sizeof(s->sd.name), "n1x-seninf");
	s->pads[SENINF_PAD_SINK].flags = MEDIA_PAD_FL_SINK;
	s->pads[SENINF_PAD_SRC].flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&s->sd.entity, SENINF_NUM_PADS, s->pads);
	if (ret)
		goto err_v4l2;

	ret = v4l2_device_register_subdev(&s->v4l2_dev, &s->sd);
	if (ret)
		goto err_entity;

	ret = media_device_register(&s->mdev);
	if (ret)
		goto err_subdev;

	v4l2_async_nf_init(&s->notifier, &s->v4l2_dev);
	s->notifier.ops = &n1x_seninf_nf_ops;

	ret = n1x_seninf_parse_graph(s);
	if (ret) {
		dev_err(dev, "no sensor endpoints (load yoga9n-cam first)\n");
		goto err_nf;
	}

	ret = v4l2_async_nf_register(&s->notifier);
	if (ret)
		goto err_nf;

	dev_info(dev, "stage-0 bridge ready (no register access)\n");
	return 0;

err_nf:
	v4l2_async_nf_cleanup(&s->notifier);
	media_device_unregister(&s->mdev);
err_subdev:
	v4l2_device_unregister_subdev(&s->sd);
err_entity:
	media_entity_cleanup(&s->sd.entity);
err_v4l2:
	v4l2_device_unregister(&s->v4l2_dev);
err_mdev:
	media_device_cleanup(&s->mdev);
	return ret;
}

static void n1x_seninf_remove(struct platform_device *pdev)
{
	struct n1x_seninf *s = platform_get_drvdata(pdev);

	v4l2_async_nf_unregister(&s->notifier);
	v4l2_async_nf_cleanup(&s->notifier);
	media_device_unregister(&s->mdev);
	v4l2_device_unregister_subdev(&s->sd);
	media_entity_cleanup(&s->sd.entity);
	v4l2_device_unregister(&s->v4l2_dev);
	media_device_cleanup(&s->mdev);
}

static const struct acpi_device_id n1x_seninf_acpi_ids[] = {
	{ "NVDA2820" },
	{ }
};
MODULE_DEVICE_TABLE(acpi, n1x_seninf_acpi_ids);

static struct platform_driver n1x_seninf_driver = {
	.probe = n1x_seninf_probe,
	.remove = n1x_seninf_remove,
	.driver = {
		.name = "n1x-seninf",
		.acpi_match_table = n1x_seninf_acpi_ids,
	},
};
module_platform_driver(n1x_seninf_driver);

MODULE_DESCRIPTION("NVIDIA N1X / MediaTek MT8991 SENINF CSI-2 receiver (stage 0)");
MODULE_LICENSE("GPL");
