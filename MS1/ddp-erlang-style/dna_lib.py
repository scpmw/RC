__author__ = 'mcsquaredjr'

import os
import socket

NODE_FILE = os.environ["NODES"]
CAD_FILE = os.environ["CAD"]
PROC_PER_NODE = os.environ["PROCS_PER_NODE"]
ITEMCOUNT = os.environ["ITEMCOUNT"]
DDP = os.environment["DDP"]
DDP_OPTS = os.environ["DDP_OPTS"]
MIN_PORT = os.environment["NIN_PORT"]



def get_ip():
    return socket.gethostbyname(socket.gethostname())


def my_lines():
    ip = get_ip()
    with open(CAD_FILE, "r") as cad:
        lines = []
        for line in cad:
            ip_str, port = line.split(":")
            if ip_str == ip:
                lines.append(line)
    return lines


def host_no():
    ip = get_ip()
    with open(CAD_FILE, "r") as cad:
        i = 0
        for line in cad:
            ip_str, port = line.split(":")
            if ip_str == ip:
                return i / PROC_PER_NODE
            i += 1


def chunk_numbers():
    cnum = []
    hn = host_no()
    for i in range(hn, hn + PROC_PER_NODE):
        if i == 0 or i == 1:
            cnum.append(i)
        else:
            cnum.append(i - 1)
    return cnum


def chunk_count():
    with open(CAD_FILE) as cad:
        for i, l in enumerate(cad):
            pass
    return i + 1 - 2


def roles():
    roles = []
    hn = host_no()
    for i in range(hn, hn + PROC_PER_NODE):
        if i == 0:
            roles.append("master")
        else:
            roles.append("slave")



if __name__ == '__main__':
    "My IP is:", get_ip()