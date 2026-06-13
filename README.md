<div align="center">

# 945GSE-overclock-ram-timings

</div>

---

### Introduction

Script for overclocking ram by changing pointers in MCHBAR.

---

### Compatibility

**This script will only work on devices with the 945GSE chipset!**

Script requires a Linux kernel with the /dev/mem character device enabled and parameter CONFIG_STRICT_DEVMEM disabled. You may need to write **iomem=relaxed** to GRUB_CMDLINE_LINUX_DEFAULT.

**Not all devices with the 945GSE chipset can change registers in MCHBAR!**

Therefore, the best option for changing RAM timings **is a BIOS with support for changing RAM parameters or flashing the SPD chip itself using a programmer**.

---

### License

Script is licensed under the [GNU General Public License v3](http://www.gnu.org/copyleft/gpl.html).
