#! /bin/sh -x
# Execute command by failover.
# special values:  %d = node id
#                  %H = new master node host name
#                  %P = old primary node id
falling_node=$1          # %d
old_primary=$2           # %P
new_primary=$3           # %H
trigger_file=$4

pghome=/usr/lib/postgresql/9.5
log=/var/log/pgpool/failover.log

date >> $log
echo "failed_node_id=$falling_node new_primary=$new_primary" >> $log

if [ $falling_node = $old_primary ]; then
	if [ $UID = 0 ];then
        	su postgres
    	fi
    	exit 0;
	ssh -T postgres@$new_primary touch $trigger_file
fi;
exit 0;
