// SPDX-License-Identifier: GPL-2.0
/*
 * Lenovo Yoga 9 2-in-1 16N1X11 (83N7, NVIDIA N1X): camera sensor glue.
 *
 * The DSDT describes the front sensor \_SB.CAMF (NVDA2810, OmniVision
 * OV08X40) with only two GpioIo and two I2cSerialBus resources:
 *
 *   _CRS[0] GpioIo GIO0 pin 0x22  "campower"  (per _DSM fn 2)
 *   _CRS[1] GpioIo GIO0 pin 0x27  "reset"
 *   I2C0 0x10 sensor, 0x50 EEPROM, 400 kHz
 *
 * There is no _DSD, no clock and no CSI-2 endpoint description. This module
 * supplies what ov08x40 needs to probe:
 *
 *   - an ACPI GPIO mapping, so "reset" resolves to _CRS[1] (active low:
 *     firmware leaves the line high and the sensor answers chip-ID reads)
 *     and "campower" to _CRS[0];
 *   - a software node (secondary fwnode) with clock-frequency = 19.2 MHz,
 *     from which v4l2 registers a fixed dummy clock, and a port/endpoint
 *     with 4 CSI-2 D-PHY data lanes at 400 MHz.
 *
 * campower is claimed here and driven high for as long as the module is
 * loaded, matching what firmware leaves behind. ov08x40 sees dummy
 * regulators.
 *
 * NOT described: the real sensor MCLK (CMMCLK pin mux + camtg clock).
 * Register access works without it; streaming will not.
 *
 * Lane count and link frequency are assumptions (the sensor's 4-lane modes
 * all use 400 MHz); they only matter once a CSI-2 receiver exists.
 *
 * Load this module first, then ov08x40 (patched with the NVDA2810 ID).
 */

#include <linux/acpi.h>
#include <linux/device.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/property.h>
#include <dt-bindings/media/video-interfaces.h>

#define YOGA_CAMF_HID		"NVDA2810"
#define YOGA_SENI_HID		"NVDA2820"	/* SENINF; CAMF uses csiport 0 */
#define YOGA_CAMF_MCLK_HZ	19200000
#define YOGA_CAMF_LINK_FREQ	400000000ULL

static const struct acpi_gpio_params campower_gpio = { 0, 0, false };
static const struct acpi_gpio_params reset_gpio    = { 1, 0, true };

static const struct acpi_gpio_mapping yoga_camf_gpios[] = {
	{ "campower-gpios", &campower_gpio, 1 },
	{ "reset-gpios", &reset_gpio, 1 },
	{ }
};

static const u32 yoga_camf_data_lanes[] = { 1, 2, 3, 4 };
static const u64 yoga_camf_link_freqs[] = { YOGA_CAMF_LINK_FREQ };

static const struct property_entry yoga_camf_sensor_props[] = {
	PROPERTY_ENTRY_U32("clock-frequency", YOGA_CAMF_MCLK_HZ),
	{ }
};

/* The two endpoints reference each other. */
static const struct software_node yoga_camf_ep_node;
static const struct software_node yoga_seni_ep_node;

static const struct property_entry yoga_camf_ep_props[] = {
	PROPERTY_ENTRY_U32("bus-type", MEDIA_BUS_TYPE_CSI2_DPHY),
	PROPERTY_ENTRY_U32_ARRAY("data-lanes", yoga_camf_data_lanes),
	PROPERTY_ENTRY_U64_ARRAY("link-frequencies", yoga_camf_link_freqs),
	PROPERTY_ENTRY_REF("remote-endpoint", &yoga_seni_ep_node),
	{ }
};

static const struct property_entry yoga_seni_ep_props[] = {
	PROPERTY_ENTRY_U32("bus-type", MEDIA_BUS_TYPE_CSI2_DPHY),
	PROPERTY_ENTRY_U32_ARRAY("data-lanes", yoga_camf_data_lanes),
	PROPERTY_ENTRY_REF("remote-endpoint", &yoga_camf_ep_node),
	{ }
};

static const struct software_node yoga_camf_sensor_node = {
	.name = "yoga9n-ov08x40",
	.properties = yoga_camf_sensor_props,
};

static const struct software_node yoga_camf_port_node = {
	.name = "port@0",
	.parent = &yoga_camf_sensor_node,
};

static const struct software_node yoga_camf_ep_node = {
	.name = "endpoint@0",
	.parent = &yoga_camf_port_node,
	.properties = yoga_camf_ep_props,
};

static const struct software_node yoga_seni_node = {
	.name = "yoga9n-seninf",
};

static const struct software_node yoga_seni_port_node = {
	.name = "port@0",		/* = CAMF HWIF csiport 0 */
	.parent = &yoga_seni_node,
};

static const struct software_node yoga_seni_ep_node = {
	.name = "endpoint@0",
	.parent = &yoga_seni_port_node,
	.properties = yoga_seni_ep_props,
};

static const struct software_node *yoga_camf_nodes[] = {
	&yoga_camf_sensor_node,
	&yoga_camf_port_node,
	&yoga_camf_ep_node,
	&yoga_seni_node,
	&yoga_seni_port_node,
	&yoga_seni_ep_node,
	NULL
};

static struct acpi_device *camf_adev;
static struct i2c_client *camf_client;
static struct gpio_desc *camf_power;
static struct acpi_device *seni_adev;
static struct device *seni_dev;
static bool nodes_registered, node_attached, seni_node_attached;

static void yoga9n_cam_cleanup(void)
{
	if (seni_dev) {
		device_release_driver(seni_dev);
		if (seni_node_attached)
			device_remove_software_node(seni_dev);
		put_device(seni_dev);
	}
	if (seni_adev)
		acpi_dev_put(seni_adev);
	if (camf_client) {
		/* ov08x40 must let go before its fwnode/GPIO mapping vanish. */
		device_release_driver(&camf_client->dev);
		if (node_attached)
			device_remove_software_node(&camf_client->dev);
	}
	if (camf_power)
		gpiod_put(camf_power);	/* line keeps its last (high) value */
	if (camf_adev)
		acpi_dev_remove_driver_gpios(camf_adev);
	if (nodes_registered)
		software_node_unregister_node_group(yoga_camf_nodes);
	if (camf_client)
		put_device(&camf_client->dev);
	if (camf_adev)
		acpi_dev_put(camf_adev);
}

static int __init yoga9n_cam_init(void)
{
	int ret;

	camf_adev = acpi_dev_get_first_match_dev(YOGA_CAMF_HID, NULL, -1);
	if (!camf_adev)
		return -ENODEV;

	camf_client = i2c_find_device_by_fwnode(acpi_fwnode_handle(camf_adev));
	if (!camf_client) {
		pr_err("yoga9n-cam: no I2C client for %s\n", YOGA_CAMF_HID);
		ret = -ENODEV;
		goto err;
	}
	if (camf_client->dev.driver) {
		pr_err("yoga9n-cam: %s already bound to %s; unload it first\n",
		       dev_name(&camf_client->dev), camf_client->dev.driver->name);
		ret = -EBUSY;
		goto err;
	}

	ret = acpi_dev_add_driver_gpios(camf_adev, yoga_camf_gpios);
	if (ret)
		goto err;

	camf_power = gpiod_get(&camf_client->dev, "campower", GPIOD_OUT_HIGH);
	if (IS_ERR(camf_power)) {
		ret = PTR_ERR(camf_power);
		camf_power = NULL;
		dev_err(&camf_client->dev, "yoga9n-cam: campower GPIO: %d\n", ret);
		goto err;
	}

	ret = software_node_register_node_group(yoga_camf_nodes);
	if (ret)
		goto err;
	nodes_registered = true;

	ret = device_add_software_node(&camf_client->dev, &yoga_camf_sensor_node);
	if (ret)
		goto err;
	node_attached = true;

	dev_info(&camf_client->dev,
		 "yoga9n-cam: campower on, reset/endpoint/clock described\n");

	/* SENINF side of the graph, for the bridge driver. Optional. */
	seni_adev = acpi_dev_get_first_match_dev(YOGA_SENI_HID, NULL, -1);
	if (seni_adev)
		seni_dev = get_device(acpi_get_first_physical_node(seni_adev));
	if (seni_dev && !seni_dev->driver) {
		ret = device_add_software_node(seni_dev, &yoga_seni_node);
		if (ret)
			dev_warn(seni_dev, "yoga9n-cam: seninf node: %d\n", ret);
		else
			seni_node_attached = true;
	} else if (seni_dev) {
		dev_warn(seni_dev, "yoga9n-cam: already bound, graph not added\n");
	}

	/* Bind now if ov08x40 is already loaded; harmless otherwise. */
	ret = device_attach(&camf_client->dev);
	if (ret < 0)
		dev_warn(&camf_client->dev, "yoga9n-cam: attach: %d\n", ret);

	return 0;

err:
	yoga9n_cam_cleanup();
	return ret;
}

static void __exit yoga9n_cam_exit(void)
{
	yoga9n_cam_cleanup();
}

module_init(yoga9n_cam_init);
module_exit(yoga9n_cam_exit);

MODULE_DESCRIPTION("Lenovo Yoga 9 2-in-1 16N1X11 camera sensor glue");
MODULE_LICENSE("GPL");
