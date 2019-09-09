#!/bin/bash

#### tpcc_bench variables
TPCC_PATH=/home/crlee/bench-lemp/tpcc-mysql
DB_NAME=tpcc_bench

#### Parameters
NUM_DEV=4
NUM_PHP=2
TEST_TYPE=non-iod
ARR_SCALE=(3) # total # of containers = SCALE * 4

ARR_CONNECT=(100)
#### Container parameters
## Swap types: single multiple private
# ARR_SWAP_TYPE=(private)
ARR_SWAP_TYPE=(private)

DOCKER_ROOT=/var/lib/docker
MAX_MEM=500
MEM_RATIO1=30
MEM_RATIO2=30
MEM_RATIO3=15
MEM_RATIO4=15

pid_waits() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Waiting the pids - ${INTERNAL_DIR} $(tput sgr 0)"
    PIDS=("${!1}")
    for pid in "${PIDS[*]}"; do
        wait $pid
    done
}

pid_kills() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Kill the pids - ${INTERNAL_DIR} $(tput sgr 0)"
	PIDS=("${!1}")
	for pid in "${PIDS[*]}"; do
		kill -15 $pid
	done
}

delPart() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Delete existing nvme partition$(tput sgr 0)"
	for DEV_ID in $(seq 1 4); do
		echo -e "d\nw" | fdisk /dev/nvme1n1
	done
}

genPart() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Regenerate nvme partition$(tput sgr 0)"
	SIZE=117210704
	for DEV_ID in $(seq 1 4); do
		echo -e "n\np\n${DEV_ID}\n\n+${SIZE}\nw" | fdisk /dev/nvme1n1
	done
	sleep 3
}

nvme_format() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Format nvme block devices - ${INTERNAL_DIR} $(tput sgr 0)"
	# delPart
    nvme format /dev/nvme1n1p1 -n 1 --ses=0
	nvme format /dev/nvme1n1p2 -n 1 --ses=0
	nvme format /dev/nvme1n1p3 -n 1 --ses=0
	nvme format /dev/nvme1n1p4 -n 1 --ses=0
    sleep 300

    # FLAG=true
    # while $FLAG; do
    #     NUSE="$(nvme id-ns /dev/nvme1n1 -n 1 | grep nuse | awk '{print $3}')"
    #     if [[ $NUSE -eq "0" ]]; then
    #         FLAG=false
    #         echo "nvme format done"
    #     fi
    # done
    # sleep 1
	 genPart
}

nvme_flush() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Flush nvme block devices - ${INTERNAL_DIR} $(tput sgr 0)"
    nvme flush /dev/nvme1n1
}

docker_remove() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Start removing existing docker - ${INTERNAL_DIR} $(tput sgr 0)"
	rm -rf $INTERNAL_DIR && mkdir -p $INTERNAL_DIR
    docker ps -aq | xargs --no-run-if-empty docker stop \
    && docker ps -aq | xargs --no-run-if-empty docker rm \
	&& docker system prune --all -f \
    && systemctl stop docker

	rm -rf ${DOCKER_ROOT}

	for DEV_ID in $(seq 1 4); do
		if [ -e /mnt/nvme1n1p${DEV_ID}/swapfile ]; then
			/home/mkwon/src/util-linux-swap/swapoff /mnt/nvme1n1p${DEV_ID}/swapfile
		fi
	done

    for DEV_ID in $(seq 1 4); do
        if mountpoint -q /mnt/nvme1n1p${DEV_ID}; then
            umount /mnt/nvme1n1p${DEV_ID}
        fi
        rm -rf /mnt/nvme1n1p${DEV_ID} \
        && mkdir -p /mnt/nvme1n1p${DEV_ID}
    done
	#wipefs --all --force /dev/nvme1n1

	targets=($(brctl show | grep br- | awk '{print $1}'))
	for target in ${targets[@]}; do
		ifconfig $target down
		brctl delbr $target
	done
}

docker_init() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Initializing docker engine - ${INTERNAL_DIR} $(tput sgr 0)"
    for DEV_ID in $(seq 1 ${NUM_DEV}); do
        mkfs.xfs /dev/nvme1n1p${DEV_ID} \
        && mount /dev/nvme1n1p${DEV_ID} /mnt/nvme1n1p${DEV_ID}
    done

	count=1
	for DEV_ID in $(seq 1 4); do
		cp docker/database/my.cnf /mnt/nvme1n1p${DEV_ID}/my.cnf
		MNT_DIR=/mnt/nvme1n1p${DEV_ID}

		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			NGINX_DIR=${MNT_DIR}/nginx${SCALE_ID}
			PHP_DIR=${MNT_DIR}/nginx${SCALE_ID}-php

			mkdir -p ${NGINX_DIR} ${PHP_DIR}
			mkdir -p ${NGINX_DIR}/nginx-log ${NGINX_DIR}/webpage
			for PHP_ID in $(seq 1 ${NUM_PHP}); do
				mkdir -p ${PHP_DIR}/php-log${PHP_ID}
			done

			cp docker/webpage/index.php ${NGINX_DIR}/webpage/index.php
			cp docker/php/www.conf ${PHP_DIR}/php.conf
			cp docker/php/Dockerfile ${PHP_DIR}/Dockerfile
			cp docker/nginx/default.conf ${NGINX_DIR}/nginx.conf
			cp docker/nginx/Dockerfile ${NGINX_DIR}/Dockerfile

			sed -i "s|nginx:9000|nginx${count}:9000|" ${PHP_DIR}/php.conf
			sed -i "s|\${SCALE_ID}|${count}|" ${NGINX_DIR}/nginx.conf
			sed -i "s|HOST_NAME|database${DEV_ID}|" ${NGINX_DIR}/webpage/index.php
			sed -i "s|MYSQL_USER|username${SCALE_ID}|" ${NGINX_DIR}/webpage/index.php
			sed -i "s|MYSQL_PASSWORD|userpassword${SCALE_ID}|" ${NGINX_DIR}/webpage/index.php
			sed -i "s|MYSQL_DATABASE|tpcc_bench${SCALE_ID}|" ${NGINX_DIR}/webpage/index.php
			let count="$count + 1"
		done
	done

	iptables -t nat -N DOCKER
	iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
	iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL ! --dst 172.17.0.1/8 -j DOCKER

	service iptables save
	service iptables restart
	# iptables -L
	systemctl restart docker

	# >/var/log/messages
}

swapfile_init() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Initializing private swapfile - ${INTERNAL_DIR} $(tput sgr 0)"

	if [ $SWAP_TYPE == "single" ]; then
		let SWAPSIZE="1024 * $NUM_SCALE * $NUM_DEV"
		SWAPFILE=/mnt/nvme1n1p1/swapfile
		if [ ! -f $SWAPFILE ]; then
			dd if=/dev/zero of=$SWAPFILE bs=1M count=$SWAPSIZE
			chmod 600 $SWAPFILE
			mkswap $SWAPFILE
		fi
		echo "/mnt/nvme1n1p1/swapfile swap swap defaults,pri=60 0 0" >> /etc/fstab

		tmp=$(xfs_bmap -v /mnt/nvme1n1p1/swapfile | awk 'FNR == 3 { print $3 }')
		min=$(echo $tmp | cut -d. -f1)
		max=$(echo $tmp | cut -d. -f3)
		echo $SWAPFILE $min $max > ${INTERNAL_DIR}/swapfile_addr.txt
	else
		let SWAPSIZE="1024 * $NUM_SCALE"
		for DEV_ID in $(seq 1 4); do
			SWAPFILE=/mnt/nvme1n1p${DEV_ID}/swapfile
			if [ ! -f $SWAPFILE ]; then
				dd if=/dev/zero of=$SWAPFILE bs=1M count=$SWAPSIZE # 1G
				chmod 600 $SWAPFILE
				mkswap $SWAPFILE
			fi
			if [ $SWAP_TYPE == "private" ]; then
				echo "/mnt/nvme1n1p${DEV_ID}/swapfile swap swap defaults,cgroup 0 0" >> /etc/fstab
			else
				echo "/mnt/nvme1n1p${DEV_ID}/swapfile swap swap defaults,pri=60 0 0" >> /etc/fstab
			fi

			tmp=$(xfs_bmap -v /mnt/nvme1n1p${DEV_ID}/swapfile | awk 'FNR == 3 { print $3 }')
			min=$(echo $tmp | cut -d. -f1)
			max=$(echo $tmp | cut -d. -f3)
			echo $SWAPFILE $min $max >> ${INTERNAL_DIR}/swapfile_addr.txt
		done
	fi

	/home/mkwon/src/util-linux-swap/swapon -a
	awk '$1 !~/swapfile/ {print }' /etc/fstab > /etc/fstab.bak
	rm -rf /etc/fstab && mv /etc/fstab.bak /etc/fstab
}

docker_healthy() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Check docker healthy - ${INTERNAL_DIR} $(tput sgr 0)"
	while docker ps -a | grep -c 'starting\|unhealthy' > /dev/null;
	do
		sleep 1;
	done
}

mysql_db_gen() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Generate Mysql DB data file - ${INTERNAL_DIR} $(tput sgr 0)"
	rm -rf ./docker/database/db-home/mysql-init-files/*
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		cp scripts/setup.sql setup${SCALE_ID}.sql
		sed -i "s|username|username${SCALE_ID}|" setup${SCALE_ID}.sql
		sed -i "s|userpassword|userpassword${SCALE_ID}|" setup${SCALE_ID}.sql
		sed -i "s|tpcc_bench|tpcc_bench${SCALE_ID}|" setup${SCALE_ID}.sql
		sed -i "s|\${MNT_DIR}|/mnt/nvme1n1p${DEV_ID}|" setup${SCALE_ID}.sql
		mv setup${SCALE_ID}.sql ./docker/database/db-home/mysql-init-files/
	done
}

dockerfile_gen() {
	## Cleanup 
	echo "$(tput setaf 4 bold)$(tput setab 7)Generating docker-compose file - ${INTERNAL_DIR} $(tput sgr 0)"
	rm -rf scripts/docker-compose.server.yml
	rm -rf scripts/docker-compose.db.yml

	## DB dockerfile generation
	let DB_MEM1="$MAX_MEM * $MEM_RATIO1 / 100"
	let DB_MEM2="$MAX_MEM * $MEM_RATIO2 / 100"
	let DB_MEM3="$MAX_MEM * $MEM_RATIO3 / 100"
	let DB_MEM4="$MAX_MEM * $MEM_RATIO4 / 100"

	cp scripts/docker-compose.db.yml.template scripts/docker-compose.db.yml
	sed -i "s|\${DB_MEM1}|${DB_MEM1}|" scripts/docker-compose.db.yml
	sed -i "s|\${DB_MEM2}|${DB_MEM2}|" scripts/docker-compose.db.yml
	sed -i "s|\${DB_MEM3}|${DB_MEM3}|" scripts/docker-compose.db.yml
	sed -i "s|\${DB_MEM4}|${DB_MEM4}|" scripts/docker-compose.db.yml

	if [ $SWAP_TYPE == "single" ] || [ $SWAP_TYPE == "multiple" ]; then
		sed -i '/swapfile/d' scripts/docker-compose.db.yml
	fi

	count=1
	for DEV_ID in $(seq 1 4); do
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			NGINX_PORT=$((8079+${count}))
			cp scripts/docker-compose.server.yml.template scripts/docker-compose.NS${DEV_ID}-server${SCALE_ID}.yml
			sed -i "s|8080|${NGINX_PORT}|" scripts/docker-compose.NS${DEV_ID}-server${SCALE_ID}.yml
			sed -i "s|\${MNT_DIR}|/mnt/nvme1n1p${DEV_ID}|" scripts/docker-compose.NS${DEV_ID}-server${SCALE_ID}.yml
			sed -i "s|\${SCALE_ID}|${SCALE_ID}|" scripts/docker-compose.NS${DEV_ID}-server${SCALE_ID}.yml
			sed -i "s|\${DEV_ID}|${DEV_ID}|" scripts/docker-compose.NS${DEV_ID}-server${SCALE_ID}.yml
			sed -i "s|\${count}|${count}|" scripts/docker-compose.NS${DEV_ID}-server${SCALE_ID}.yml
			let count="$count + 1"
		done
	done

	## Merge multiple web service compose files
	for DEV_ID in $(seq 1 4); do
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			cat "scripts/docker-compose.NS${DEV_ID}-server${SCALE_ID}.yml" >> scripts/docker-compose.server.yml
		done
	done
	sed -i "1i\services:" scripts/docker-compose.server.yml
	sed -i "1i\version: '2.4'" scripts/docker-compose.server.yml
	echo "networks:" >> scripts/docker-compose.server.yml
	echo " shared1:" >> scripts/docker-compose.server.yml
	echo "  external:" >> scripts/docker-compose.server.yml
	echo "   name: shared1" >> scripts/docker-compose.server.yml
	echo " shared2:" >> scripts/docker-compose.server.yml
	echo "  external:" >> scripts/docker-compose.server.yml
	echo "   name: shared2" >> scripts/docker-compose.server.yml
	echo " shared3:" >> scripts/docker-compose.server.yml
	echo "  external:" >> scripts/docker-compose.server.yml
	echo "   name: shared3" >> scripts/docker-compose.server.yml
	echo " shared4:" >> scripts/docker-compose.server.yml
	echo "  external:" >> scripts/docker-compose.server.yml
	echo "   name: shared4" >> scripts/docker-compose.server.yml	
	## Cleanup temporal scripts
	rm -rf scripts/docker-compose.NS*
}

docker_web_gen() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Generating web containers - ${INTERNAL_DIR} $(tput sgr 0)"
	
	for DEV_ID in $(seq 1 4); do
		if [[ -n $(docker network ls | grep shared${DEV_ID}) ]]; then
			echo "please cleanup docker network"
		else
			docker network create shared${DEV_ID}
		fi
	done

	### Build the docker-compose service containers
	docker-compose -f scripts/docker-compose.db.yml -f scripts/docker-compose.server.yml build --parallel database1 database2 database3 database4 
	for DEV_ID in $(seq 1 4); do
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			let CONT_ID="$SCALE_ID + $NUM_SCALE * ($DEV_ID - 1)"
			# ${NUM_PHP} 
			docker-compose -f scripts/docker-compose.db.yml -f scripts/docker-compose.server.yml build --parallel nginx${CONT_ID} nginx${CONT_ID}-php1 nginx${CONT_ID}-php2
		done
	done

	### Up the docker-compose service containers
	docker-compose -f scripts/docker-compose.db.yml -f scripts/docker-compose.server.yml up -d database1 database2 database3 database4
	for DEV_ID in $(seq 1 4); do
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			let CONT_ID="$SCALE_ID + $NUM_SCALE * ($DEV_ID - 1)"
			# ${NUM_PHP} 
			docker-compose -f scripts/docker-compose.db.yml -f scripts/docker-compose.server.yml up -d nginx${CONT_ID}-php1 nginx${CONT_ID}-php2
			docker_healthy
			docker-compose -f scripts/docker-compose.db.yml -f scripts/docker-compose.server.yml up -d nginx${CONT_ID}
		done
	done

	sleep 5
	docker_healthy
	
	for DEV_ID in $(seq 1 4); do
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			docker exec -i database${DEV_ID} mysql -uroot -proot <<< "source /home/mysql/setup"${SCALE_ID}".sql"
			docker exec -i database${DEV_ID} mysql -uroot -proot <<< "set global max_connections=4096;"
		done
	done
}

docker_web_init() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Initializing web container tables - ${INTERNAL_DIR} $(tput sgr 0)"

	TPCC_PIDS=()
	for DEV_ID in $(seq 1 4); do
		CONT_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' database${DEV_ID})" 
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			DB_NAME=tpcc_bench${SCALE_ID}
			USER_NAME=username${SCALE_ID}
			USER_PASSWD=userpassword${SCALE_ID}
			${TPCC_PATH}/tpcc_load -h $CONT_IP -d $DB_NAME -u ${USER_NAME} -p ${USER_PASSWD} -w 1 -s 1 & TPCC_PIDS+=("$!")
		done
	done
	pid_waits TPCC_PIDS[@]
	sleep 5
}

log_cleanup() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Enable logging - ${INTERNAL_DIR} $(tput sgr 0)"
	for DEV_ID in $(seq 1 4); do
		MNT_DIR=/mnt/nvme1n1p${DEV_ID}
		>${MNT_DIR}/db-root/mysql-slow.log
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			>${MNT_DIR}/nginx${SCALE_ID}/nginx-log/api_access.log
			for PHP_ID in $(seq 1 ${NUM_PHP}); do
				>${MNT_DIR}/nginx${SCALE_ID}-php/php-log${PHP_ID}/access.log
			done
		done
		docker exec -i database${DEV_ID} mysql -uroot -proot <<< "SET GLOBAL slow_query_log = 'ON';"
	done
}

docker_web_run() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Execute TPCC-bench - ${INTERNAL_DIR} $(tput sgr 0)"

	log_cleanup

	#### Change  service name to IP address to remove error
	#### 'php_network_getaddress: getaddrinfo failed: Temporary failure in name resolution'
	count=1
	for DEV_ID in $(seq 1 4); do
		MNT_DIR=/mnt/nvme1n1p${DEV_ID}
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			NGINX_DIR=${MNT_DIR}/nginx${SCALE_ID}
			IP_ADDR="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' database${DEV_ID})"
			sed -i "s|database${DEV_ID}|${IP_ADDR}|" ${NGINX_DIR}/webpage/index.php
			for PHP_ID in $(seq 1 ${NUM_PHP}); do
				SERVICE_NAME=nginx${count}-php${PHP_ID}
				IP_ADDR="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${SERVICE_NAME})"
				sed -i "s|${SERVICE_NAME}|${IP_ADDR}|" ${NGINX_DIR}/nginx.conf
			done
			let count="$count + 1"
		done
	done

	#### Execute tpcc_start
	count=1
	TPCC_PIDS=()
	for DEV_ID in $(seq 1 4); do
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			PORT_NUM=$((8079+${count}))
			${TPCC_PATH}/tpcc_start -h http://127.0.0.1:${PORT_NUM}/index.php -P ${PORT_NUM} -e 1 -d ${TPCC_PATH}/seed.txt -w 1 -c ${NUM_CONNECT} -r 10 -l 180 > ${INTERNAL_DIR}/NS${DEV_ID}-SCALE${SCALE_ID}.tpcc 2>&1 & TPCC_PIDS+=("$!")
			let count="$count + 1"
		done
	done
	pid_waits TPCC_PIDS[@] 

	sleep 5

	log_copy
}

log_copy() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Copy logs - ${INTERNAL_DIR} $(tput sgr 0)"
	sync; echo 3 > /proc/sys/vm/drop_caches

	cp scripts/docker-compose.db.yml scripts/docker-compose.server.yml $INTERNAL_DIR/
	for DEV_ID in $(seq 1 4); do
		MNT_DIR=/mnt/nvme1n1p${DEV_ID}
		cp ${MNT_DIR}/db-root/mysql-slow.log $INTERNAL_DIR/NS${DEV_ID}-mysql.log
		for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
			cp ${MNT_DIR}/nginx${SCALE_ID}/nginx-log/api_access.log $INTERNAL_DIR/NS${DEV_ID}-nginx${SCALE_ID}.log
			for PHP_ID in $(seq 1 ${NUM_PHP}); do
				cp ${MNT_DIR}/nginx${SCALE_ID}-php/php-log${PHP_ID}/access.log $INTERNAL_DIR/NS${DEV_ID}-nginx${SCALE_ID}-php${PHP_ID}.log
			done
		done
	done
}

anal_start() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Enable analysis - ${INTERNAL_DIR} $(tput sgr 0)"
	BLKTRACE_PIDS=()
	for DEV_ID in $(seq 1 4); do
		blktrace -d /dev/nvme1n1p${DEV_ID} -w 600 -D ${INTERNAL_DIR} & BLKTRACE_PIDS+=("$!")
	done
}

anal_end() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Disable analysis - ${INTERNAL_DIR} $(tput sgr 0)"
	pid_kills BLKTRACE_PIDS[@]
	sleep 10
}

for NUM_CONNECT in "${ARR_CONNECT[@]}"; do
	for NUM_SCALE in "${ARR_SCALE[@]}"; do
		for SWAP_TYPE in "${ARR_SWAP_TYPE[@]}"; do
			RESULT_DIR=/home/crlee/${TEST_TYPE}/swap-${SWAP_TYPE} && mkdir -p ${RESULT_DIR}
			INTERNAL_DIR=${RESULT_DIR}/SCALE${NUM_SCALE}-CONNECT${NUM_CONNECT}
			
			#### Docker initialization
			docker_remove
			nvme_flush
			nvme_format

			docker_init
			swapfile_init
			mysql_db_gen
			dockerfile_gen
			docker_web_gen
			docker_web_init
			# anal_start
			# # # smem_start
			docker_web_run
			# anal_end
			# # # smem_end
		done
	done
done
