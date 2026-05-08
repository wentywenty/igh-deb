#!/bin/bash
set -e
depmod -a
systemctl restart ethercat
