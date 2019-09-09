from __future__ import print_function
import warnings
warnings.filterwarnings('ignore')
import sys
import os
import re
import numpy as np

regexPHP = re.compile('200\s(\d+(\.\d*)?|\.\d+)ms')
regexNGNX = re.compile('\"rt=(\d+(\.\d*)?|\.\d+)')
regexDB = re.compile('#\sQuery_time\:\s(\d+(\.\d+)?)')

ARR_SWAP_TYPE=["single", "multiple", "private"]
# ARR_SWAP_TYPE=["private"]
ARR_SCALE = [3]
ARR_CONNECT = [100]
NUM_PHP = 2
TEST_TYPE="bench-lemp"

def mysql_parser(FULL_PATH, NUM_SCALE):
    for DEV_ID in range(1, 5):
        MYSQL_MERGE_PATH=FULL_PATH + "/NS" + str(DEV_ID) + "-mysql.log"
        for SCALE_ID in range(1, NUM_SCALE + 1):
            MYSQL_PATH=FULL_PATH + "/NS" + str(DEV_ID) + "-mysql" + str(SCALE_ID) + ".log"
            if os.path.isfile(MYSQL_PATH):
                os.remove(MYSQL_PATH)

            fo = open(MYSQL_PATH,"w+")

            checker = 0
            with open(MYSQL_MERGE_PATH) as f:
                f.seek(0,0)
                for line in f:
                    if checker == 1:
                        fo.write(line)
                    if "username" + str(SCALE_ID) in line:
                        checker = 1
                    else:
                        checker = 0
                    

def get_val(LOG_PATH):   
    arr_val = []
    if os.path.isfile(LOG_PATH):
        with open(LOG_PATH) as f:
            f.seek(0)
            for line in f:
                if "php" in LOG_PATH:
                    match = regexPHP.search(line)
                elif "nginx" in LOG_PATH:
                    match = regexNGNX.search(line)
                else:
                    match = regexDB.search(line)

                if match:
                    arr_val.append(float(match.group(1)))

    return arr_val

def init(NUM_SCALE, SWAP_TYPE, NUM_CONNECT):
    for DEV_ID in range(1, 5):
        for SCALE_ID in range(1, NUM_SCALE + 1):
            FULL_PATH = "/mnt/data-diff/"+ TEST_TYPE +"/swap-" + SWAP_TYPE + \
                "/SCALE" + str(NUM_SCALE) + "-CONNECT" + str(NUM_CONNECT)
            MYSQL_PATH = FULL_PATH + "/NS" + str(DEV_ID) + "-mysql" + str(SCALE_ID) + ".log"
            if os.path.isfile(MYSQL_PATH):
                os.remove(MYSQL_PATH)

def main():
    stack_type = sys.argv[1]
    for NUM_CONNECT in ARR_CONNECT:
        for NUM_SCALE in ARR_SCALE:
            print(stack_type+"-SCALE"+str(NUM_SCALE)+" Set1 Set2 Set3 Set4")
            for SWAP_TYPE in ARR_SWAP_TYPE:
                init(NUM_SCALE, SWAP_TYPE, NUM_CONNECT)
                print(SWAP_TYPE, end='')

                for DEV_ID in range(1, 5):
                    sum_php_dev, sum_nginx_dev, sum_mysql_dev = 0, 0, 0
                    arr_nginx_dev = []
                    for SCALE_ID in range(1, NUM_SCALE + 1):
                        arr_php, arr_nginx, arr_mysql = [], [], []
                        FULL_PATH = "/mnt/data-diff/"+ TEST_TYPE +"/swap-" + SWAP_TYPE + \
                            "/SCALE" + str(NUM_SCALE) + "-CONNECT" + str(NUM_CONNECT)

                        if stack_type == "mysql":
                            MYSQL_PATH = FULL_PATH + "/NS" + str(DEV_ID) + "-mysql" + str(SCALE_ID) + ".log"
                            mysql_parser(FULL_PATH, NUM_SCALE)
                            arr_mysql = get_val(MYSQL_PATH)
                            sum_mysql = np.sum(arr_mysql) * 1000 # ms
                            sum_mysql_dev = sum_mysql_dev + sum_mysql
                        elif stack_type == "nginx":
                            NGNX_PATH = FULL_PATH + "/NS" + str(DEV_ID) + "-nginx" + str(SCALE_ID) + ".log"
                            arr_nginx = get_val(NGNX_PATH)
                            sum_nginx = np.sum(arr_nginx) * 1000 # ms
                            sum_nginx_dev = sum_nginx_dev + sum_nginx
                            arr_nginx_dev = arr_nginx_dev + arr_nginx
                        else: #### NOTE!!!! we have to consider PHP load balancing
                            tmp_sum_arr = []
                            for PHP_ID in range(1, NUM_PHP + 1):
                                tmp_arr = []
                                PHP_PATH = FULL_PATH + "/NS" + str(DEV_ID) + "-nginx" + str(SCALE_ID) + "-php" + str(PHP_ID) + ".log"
                                tmp_arr = get_val(PHP_PATH)
                                tmp_sum_arr.append(np.sum(tmp_arr))
                            sum_php = np.max(tmp_sum_arr) # ms
                            sum_php_dev = sum_php_dev + sum_php

                    if stack_type == "mysql":
                        if DEV_ID == 4:
                            print(" " + str(sum_mysql_dev))
                        else:
                            print(" " + str(sum_mysql_dev), end='')
                    elif stack_type == "nginx":
                        if DEV_ID == 4:
                            #print(" " + str(sum_nginx_dev))
                            print(" " + str(np.mean(arr_nginx_dev)))
                            #print(" " + str(np.percentile(arr_nginx_dev, 99)))
                        else:
                            #print(" " + str(sum_nginx_dev), end='')
                            print(" " + str(np.mean(arr_nginx_dev)), end='')
                            #print(" " + str(np.percentile(arr_nginx_dev, 99)), end='')
                    else:
                        if DEV_ID == 4:
                            print(" " + str(sum_php_dev))
                        else:
                            print(" " + str(sum_php_dev), end='')                                  

if __name__ == "__main__":
    main()
