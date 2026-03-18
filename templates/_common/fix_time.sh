#!/bin/bash -eux

TIMEZONE="${TIMEZONE:-Israel}"
ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

# TIME_SYNCH_SERVER=
# echo Adding ntp server $TIME_SYNCH_SERVER ...
# if grep -q -i "release 8." /etc/redhat-release || grep -q -i "SLES" /etc/os-release ; then
# 	echo server $TIME_SYNCH_SERVER iburst >> /etc/chrony.conf
# 	systemctl start chronyd.service
# 	systemctl enable chronyd.service
# elif grep -q -i "release 6." /etc/redhat-release ; then
# 	echo server $TIME_SYNCH_SERVER iburst >> /etc/ntp.conf
# 	service ntpd start
# 	chkconfig --add ntpd && chkconfig ntpd on
# else
# 	echo server $TIME_SYNCH_SERVER iburst >> /etc/ntp.conf
# 	systemctl start ntpd
# 	systemctl enable ntpd
# fi
