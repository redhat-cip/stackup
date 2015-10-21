#!/bin/bash
#
# Stackup is an OpenStack instances backup tool
#
# Copyright (C) 2015 Gaëtan Trellu <gaetan.trellu@enovance.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA,
# 02110-1301, USA.

# OpenStack list clients
clients="novaclient glanceclient cinderclient keystoneclient openstackclient swiftclient ceilometerclient heatclient troveclient saharaclient neutronclient designateclient"

# Packages mandatory to install the OpenStack clients
pkgs="wget libxml2 libxml2-devel libxslt libxslt-devel python-pip python-devel libffi-devel openssl-devel gcc python-requests python-six"

# Add EPEL repo
rpm -ivh https://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm

# Install packages
yum update -y
yum install $pkgs -y

# Install the OpenStack clients with PIP
for client in $clients
do
  pip install -U python-${client}
done
