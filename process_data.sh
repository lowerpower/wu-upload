#!/bin/bash
#
# Compatibility entry point for the old lake-temperature cron.
#
# read_acurite.sh now refreshes /tmp/lake_temp.txt whenever the scheduled
# Weather Underground upload obtains a packet. Do not start another rtl_433
# process here; the SDR must have only one accessor.
exit 0
