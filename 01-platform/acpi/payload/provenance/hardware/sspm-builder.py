#!/usr/bin/env python3
"""Check the SDCN77WW SSPM override against this Yoga's own DSDT dump without writing files."""
from acpi_builder import cli

if __name__ == "__main__":
    cli(check_only=True)
