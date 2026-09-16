# /root/.profile — root autologin on tty1 runs the first-boot wizard if no
# Wi-Fi has been configured yet; otherwise just give a root shell.

if [ -x /usr/local/bin/secondscreen-wizard ] && \
   ! grep -q '^network=' /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
	/usr/local/bin/secondscreen-wizard
fi

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
