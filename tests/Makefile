SIM ?= icarus
TOPLEVEL_LANG = verilog
TOPLEVEL ?= axis_elastic_buffer
MODULE ?= test_axis_elastic_buffer

RTL_ROOT := $(abspath ../rtl)

ifeq ($(TOPLEVEL),axis_elastic_buffer)
VERILOG_SOURCES := $(RTL_ROOT)/common/axis_elastic_buffer.sv
endif
ifeq ($(TOPLEVEL),ipv4_udp_tx)
VERILOG_SOURCES := $(RTL_ROOT)/tx/ipv4_udp_tx.sv
endif
ifeq ($(TOPLEVEL),ipv4_udp_rx)
VERILOG_SOURCES := $(RTL_ROOT)/rx/ipv4_udp_rx.sv
endif
ifeq ($(TOPLEVEL),arp_tx)
VERILOG_SOURCES := $(RTL_ROOT)/arp/arp_tx.sv
endif
ifeq ($(TOPLEVEL),arp_rx)
VERILOG_SOURCES := $(RTL_ROOT)/arp/arp_rx.sv
endif

COMPILE_ARGS += -g2012 -Wall
PYTHONPATH := $(CURDIR):$(PYTHONPATH)
export PYTHONPATH

include $(shell cocotb-config --makefiles)/Makefile.sim
