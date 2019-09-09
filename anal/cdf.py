from __future__ import print_function
import warnings
warnings.filterwarnings('ignore')
import sys
import os
import re
import math
import numpy as np
import matplotlib.pyplot as plt
from bisect import bisect_left
from matplotlib.lines import Line2D

regexNGNX = re.compile('\"rt=(\d+(\.\d*)?|\.\d+)')

ARR_SWAP_TYPE=["single", "multiple", "private"]
ARR_SCALE = [3]
ARR_CONNECT = [100]
TEST_TYPE="bench-lemp"

def switch_color(swap_idx):
    return {
        1: "k",
        2: "b",
        3: "r"    
    }[swap_idx]

class discrete_cdf:
    def __init__(self, data):
        self._data = data # must be sorted
        self._data_len = float(len(data))

    def __call__(self, point):
        return (len(self._data[:bisect_left(self._data, point)]) / 
                self._data_len)

def calcdf(data):
    cdf = discrete_cdf(np.sort(data))
    xvalues = range(0, int(math.ceil(max(data))))
    yvalues = [cdf(point) for point in xvalues]
    return xvalues, yvalues

def mysql_parser(FULL_PATH, NUM_SCALE):
    for DEV_ID in range(1, 5):
        MYSQL_MERGE_PATH=FULL_PATH + "/NS" + str(DEV_ID) + "-mysql.log"
        for SCALE_ID in range(1, NUM_SCALE + 1):
            PHP_ID = SCALE_ID + NUM_SCALE * (DEV_ID - 1)
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
                    if "nginx" + str(PHP_ID) in line:
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
                    if match:
                        arr_val.append(float(match.group(1))) # ms
                elif "nginx" in LOG_PATH:
                    match = regexNGNX.search(line)
                    if match:
                        arr_val.append(float(match.group(1)) * 1000) # ms
                else:
                    match = regexDB.search(line)
                    if match:
                        arr_val.append(float(match.group(1)) * 1000) # ms

    return arr_val

def main():
    for NUM_CONNECT in ARR_CONNECT:
        for NUM_SCALE in ARR_SCALE:

            ## Figure initialization
            PATH = "SCALE" + str(NUM_SCALE) + "-CONNECT" + str(NUM_CONNECT)
            fig, axes = plt.subplots(1, 4, figsize=(17,5))
            for ax in axes.flat:
                ax.set_xscale('symlog')
            fig.suptitle(PATH)

            for DEV_ID in range(1,5):
                axes[DEV_ID-1].set_title("NS"+str(DEV_ID))
                axes[DEV_ID-1].set_xlim(10,1000)
            
            swap_idx = 0
            for SWAP_TYPE in ARR_SWAP_TYPE:
                swap_idx = swap_idx + 1
                for DEV_ID in range(1,5):
                    arr_nginx_dev = []
                    for SCALE_ID in range(1, NUM_SCALE + 1):
                        arr_nginx = []
                        FULL_PATH = "/mnt/data-diff/"+ TEST_TYPE +"/swap-" + SWAP_TYPE + \
                            "/SCALE" + str(NUM_SCALE) + "-CONNECT" + str(NUM_CONNECT)
                                                
                        NGNX_PATH = FULL_PATH + "/NS" + str(DEV_ID) + "-nginx" + str(SCALE_ID) + ".log"
                        arr_nginx = get_val(NGNX_PATH)
                        arr_nginx_dev = arr_nginx_dev + arr_nginx
                
                    print(SWAP_TYPE+"-NS"+str(DEV_ID)+" "+str(np.sum(arr_nginx_dev)))
                    color = switch_color(swap_idx)
                    xvalues, yvalues = calcdf(arr_nginx_dev)
                    axes[DEV_ID-1].plot(xvalues, yvalues, color)

            FIG_PATH = "/mnt/data-diff/"+ TEST_TYPE +"/figs/SCALE" + str(NUM_SCALE) + "-CONNECT" + str(NUM_CONNECT) + ".png"           
            custom_lines = [Line2D([0], [0], color='k', lw=4),
                            Line2D([0], [0], color='b', lw=4),
                            Line2D([0], [0], color='r', lw=4)]

            fig.legend(custom_lines,
                        labels=ARR_SWAP_TYPE,
                        loc="center right",
                        borderaxespad=0.1,
                        title="Swap method")
            plt.subplots_adjust(right=0.8)
            fig.savefig(FIG_PATH)
            plt.close(fig)

if __name__ == "__main__":
    main()
