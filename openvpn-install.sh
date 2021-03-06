#!/bin/bash
# OpenVPN road warrior installer for Debian, Ubuntu and CentOS

# This script will work on Debian, Ubuntu, CentOS and probably other distros
# of the same families, although no support is offered for them. It isn't
# bulletproof but it will probably work if you simply want to setup a VPN on
# your Debian/Ubuntu/CentOS box. It has been designed to be as unobtrusive and
# universal as possible.

# If the first argument is a directory, this script will try to
# restore/reconstruct the original OpenVPN configurations and authentication
# credentials.
# Backup the /etc/openvpn directory to save them.
OVPN_INSTALL_CONFIG_DIR=$1

# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -qs "dash"; then
	echo "This script needs to be run with bash, not sh"
	exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit 2
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "TUN is not available"
	exit 3
fi

if grep -qs "CentOS release 5" "/etc/redhat-release"; then
	echo "CentOS 5 is too old and not supported"
	exit 4
fi
if [[ -e /etc/debian_version ]]; then
	OS=debian
	GROUPNAME=nogroup
	RCLOCAL='/etc/rc.local'
elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
	OS=centos
	GROUPNAME=nobody
	RCLOCAL='/etc/rc.d/rc.local'
	# Needed for CentOS 7
	chmod +x /etc/rc.d/rc.local
else
	echo "Looks like you aren't running this installer on a Debian, Ubuntu or CentOS system"
	exit 5
fi

newclient () {
	# Generates the custom client.ovpn
	cp /etc/openvpn/client-common.txt ~/$1.ovpn
	echo "<ca>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/ca.crt >> ~/$1.ovpn
	echo "</ca>" >> ~/$1.ovpn
	echo "<cert>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/issued/$1.crt >> ~/$1.ovpn
	echo "</cert>" >> ~/$1.ovpn
	echo "<key>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/private/$1.key >> ~/$1.ovpn
	echo "</key>" >> ~/$1.ovpn
	echo "<tls-auth>" >> ~/$1.ovpn
	cat /etc/openvpn/ta.key >> ~/$1.ovpn
	echo "</tls-auth>" >> ~/$1.ovpn
}

# Try to get our IP from the system and fallback to the Internet.
# I do this to make the script compatible with NATed servers (lowendspirit.com)
# and to avoid getting an IPv6.
IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$IP" = "" ]]; then
		IP=$(wget -qO- ipv4.icanhazip.com)
fi

if [[ -e /etc/openvpn/server.conf ]]; then
	while :
	do
	clear
		echo "Looks like OpenVPN is already installed"
		echo ""
		echo "What do you want to do?"
		echo "   1) Add a cert for a new user"
		echo "   2) Revoke existing user cert"
		echo "   3) Remove OpenVPN"
		echo "   4) Exit"
		read -p "Select an option [1-4]: " option
		case $option in
			1)
			echo ""
			echo "Tell me a name for the client cert"
			echo "Please, use one word only, no special characters"
			read -p "Client name: " -e -i client CLIENT
			cd /etc/openvpn/easy-rsa/
			./easyrsa build-client-full $CLIENT nopass
			# Generates the custom client.ovpn
			newclient "$CLIENT"
			echo ""
			echo "Client $CLIENT added, configuration is available at" ~/"$CLIENT.ovpn"
			exit
			;;
			2)
			# This option could be documented a bit better and maybe even be simplimplified
			# ...but what can I say, I want some sleep too
			NUMBEROFCLIENTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$NUMBEROFCLIENTS" = '0' ]]; then
				echo ""
				echo "You have no existing clients!"
				exit 6
			fi
			echo ""
			echo "Select the existing client certificate you want to revoke"
			tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			if [[ "$NUMBEROFCLIENTS" = '1' ]]; then
				read -p "Select one client [1]: " CLIENTNUMBER
			else
				read -p "Select one client [1-$NUMBEROFCLIENTS]: " CLIENTNUMBER
			fi
			CLIENT=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$CLIENTNUMBER"p)
			cd /etc/openvpn/easy-rsa/
			./easyrsa --batch revoke $CLIENT
			./easyrsa gen-crl
			rm -rf pki/reqs/$CLIENT.req
			rm -rf pki/private/$CLIENT.key
			rm -rf pki/issued/$CLIENT.crt
			rm -rf /etc/openvpn/crl.pem
			cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
			# CRL is read with each client connection, when OpenVPN is dropped to nobody
			chown nobody:$GROUPNAME /etc/openvpn/crl.pem
			echo ""
			echo "Certificate for client $CLIENT revoked"
			exit
			;;
			3)
			echo ""
			read -p "Do you really want to remove OpenVPN? [y/n]: " -e -i n REMOVE
			if [[ "$REMOVE" = 'y' ]]; then
				PORT=$(grep '^port ' /etc/openvpn/server.conf | cut -d " " -f 2)
				[[ -f /etc/openvpn/server-tcp.conf ]] && PORT_TCP=$(grep '^port ' /etc/openvpn/server-tcp.conf | cut -d " " -f 2)
				if pgrep firewalld; then
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --zone=public --remove-port=$PORT/udp
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					[[ ! -z "$PORT_TCP" ]] && firewall-cmd --zone=public --remove-port=$PORT_TCP/tcp
					[[ ! -z "$PORT_TCP" ]] && firewall-cmd --zone=trusted --remove-source=10.9.0.0/24
					firewall-cmd --permanent --zone=public --remove-port=$PORT/udp
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
					[[ ! -z "$PORT_TCP" ]] && firewall-cmd --permanent --zone=public --remove-port=$PORT_TCP/tcp
					[[ ! -z "$PORT_TCP" ]] && firewall-cmd --permanent --zone=trusted --remove-source=10.9.0.0/24
				fi
				if iptables -L -n | grep -qE 'REJECT|DROP'; then
					sed -i "/iptables -I INPUT -p udp --dport $PORT -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -s 10.8.0.0\/24 -j ACCEPT/d" $RCLOCAL
					[[ ! -z "$PORT_TCP" ]] && sed -i "/iptables -I INPUT -p udp --dport $PORT_TCP -j ACCEPT/d" $RCLOCAL
					[[ ! -z "$PORT_TCP" ]] && sed -i "/iptables -I FORWARD -s 10.9.0.0\/24 -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT/d" $RCLOCAL
				fi
				sed -i '/iptables -t nat -A POSTROUTING -s 10.8.0.0\/24 -j SNAT --to /d' $RCLOCAL
				[[ ! -z "$PORT_TCP" ]] && sed -i '/iptables -t nat -A POSTROUTING -s 10.9.0.0\/24 -j SNAT --to /d' $RCLOCAL
				if hash sestatus 2>/dev/null; then
					if sestatus | grep "Current mode" | grep -qs "enforcing"; then
						if [[ "$PORT" != '1194' ]]; then
							semanage port -d -t openvpn_port_t -p udp $PORT
						fi
						if [[ ! -z "$PORT_TCP" ]]; then
							semanage port -d -t openvpn_port_t -p tcp $PORT_TCP
						fi
					fi
				fi
				if [[ "$OS" = 'debian' ]]; then
					apt-get remove --purge -y openvpn openvpn-blacklist
				else
					yum remove openvpn -y
				fi
				rm -rf /etc/openvpn
				rm -rf /usr/share/doc/openvpn*
				echo ""
				echo "OpenVPN removed!"
			else
				echo ""
				echo "Removal aborted!"
			fi
			exit
			;;
			4) exit;;
		esac
	done
else
	clear
	echo 'Welcome to this quick OpenVPN "road warrior" installer'
	echo ""

	HAS_CONFIG_DIR=
	if ([[ -d "$OVPN_INSTALL_CONFIG_DIR" ]] && [[ -f "$OVPN_INSTALL_CONFIG_DIR"/config.install ]]); then
		echo "I will attempt to restore openvpn configuration stored in"
		echo "$OVPN_INSTALL_CONFIG_DIR, as you've asked me to."
		echo ""

		source $OVPN_INSTALL_CONFIG_DIR/config.install
		HAS_CONFIG_DIR=1
	fi

	# OpenVPN setup and first user creation
	echo "I need to ask you a few questions before starting the setup"
	echo "You can leave the default options and just press enter if you are ok with them"
	echo ""
	echo "First I need to know the IPv4 address of the network interface you want OpenVPN"
	echo "listening to."
	[[ $HAS_CONFIG_DIR != '1' ]] && read -p "IP address: " -e -i $IP IP || echo "IP address: $IP"
	echo ""
	echo "What's the IP/hostname the client should connect to?"
	echo "If you are using a hostname you are responsible of set up the (dynamic) DNS correctly."
	[[ -z $SERVER_HOSTNAME ]] && read -p "Server hostname: " -e -i $IP SERVER_HOSTNAME || echo "Server hostname: $SERVER_HOSTNAME"
	echo ""
	echo "What port do you want for OpenVPN (UDP)?"
	[[ -z $PORT ]] && read -p "Port: " -e -i 1194 PORT || echo "Port: $PORT"
	echo ""
	echo "What port do you want for OpenVPN (TCP)?"
	([[ -z $PORT_TCP ]] && [[ $HAS_CONFIG_DIR != '1' ]]) && read -p "Port: " -e -i 443 PORT_TCP || echo "Port: $PORT_TCP"
	echo ""
	echo "What DNS do you want to use with the VPN?"
	echo "   1) Current system resolvers"
	echo "   2) Google"
	echo "   3) OpenDNS"
	echo "   4) NTT"
	echo "   5) Hurricane Electric"
	echo "   6) Verisign"
	[[ -z $DNS ]] && read -p "DNS [1-6]: " -e -i 1 DNS || echo "DNS: $DNS"
	if [[ $HAS_CONFIG_DIR != '1' ]]; then
		echo ""
		echo "Finally, tell me your name for the client cert"
		echo "Please, use one word only, no special characters"
		read -p "Client name: " -e -i client CLIENT
	fi
	echo ""
	echo "Okay, that was all I needed. We are ready to setup your OpenVPN server now"
	[[ $HAS_CONFIG_DIR = '1' ]] || read -n1 -r -p "Press any key to continue..."
		if [[ "$OS" = 'debian' ]]; then
		apt-get update
		apt-get install openvpn iptables openssl ca-certificates -y
	else
		# Else, the distro is CentOS
		yum install epel-release -y
		yum install openvpn iptables openssl wget ca-certificates -y
	fi
	# An old version of easy-rsa was available by default in some openvpn packages
	if [[ -d /etc/openvpn/easy-rsa/ ]]; then
		rm -rf /etc/openvpn/easy-rsa/
	fi
	# Get easy-rsa
	wget -O ~/EasyRSA-3.0.1.tgz https://github.com/OpenVPN/easy-rsa/releases/download/3.0.1/EasyRSA-3.0.1.tgz
	tar xzf ~/EasyRSA-3.0.1.tgz -C ~/
	mv ~/EasyRSA-3.0.1/ /etc/openvpn/
	mv /etc/openvpn/EasyRSA-3.0.1/ /etc/openvpn/easy-rsa/
	chown -R root:root /etc/openvpn/easy-rsa/
	rm -rf ~/EasyRSA-3.0.1.tgz
	cd /etc/openvpn/easy-rsa/
	if [[ -d "$OVPN_INSTALL_CONFIG_DIR/easy-rsa/pki" ]]; then
		cp -r "$OVPN_INSTALL_CONFIG_DIR/easy-rsa/pki" /etc/openvpn/easy-rsa/
		chown -R root:$GROUPNAME /etc/openvpn/easy-rsa/pki
	else
		# Create the PKI, set up the CA, the DH params and the server + client certificates
		./easyrsa init-pki
		./easyrsa --batch build-ca nopass
		./easyrsa gen-dh
		./easyrsa build-server-full server nopass
		./easyrsa build-client-full $CLIENT nopass
		./easyrsa gen-crl
	fi
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/dh.pem pki/issued/server.crt pki/private/server.key /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn
	# CRL is read with each client connection, when OpenVPN is dropped to nobody
	chown nobody:$GROUPNAME /etc/openvpn/crl.pem
	if [[ -f "$OVPN_INSTALL_CONFIG_DIR/ta.key" ]]; then
		cp "$OVPN_INSTALL_CONFIG_DIR/ta.key" /etc/openvpn/ta.key
		chown root:$GROUPNAME /etc/openvpn/ta.key
	else
		# Generate key for tls-auth
		openvpn --genkey --secret /etc/openvpn/ta.key
	fi
	# Generate server-common.conf
	echo "
dev tun
sndbuf 0
rcvbuf 0
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0
topology subnet
ifconfig-pool-persist ipp.txt" > /etc/openvpn/server-common.conf
	echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server-common.conf
	# DNS
	case $DNS in
		1)
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		grep -v '#' /etc/resolv.conf | grep 'nameserver' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read line; do
			echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server-common.conf
		done
		;;
		2)
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server-common.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server-common.conf
		;;
		3)
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server-common.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server-common.conf
		;;
		4)
		echo 'push "dhcp-option DNS 129.250.35.250"' >> /etc/openvpn/server-common.conf
		echo 'push "dhcp-option DNS 129.250.35.251"' >> /etc/openvpn/server-common.conf
		;;
		5)
		echo 'push "dhcp-option DNS 74.82.42.42"' >> /etc/openvpn/server-common.conf
		;;
		6)
		echo 'push "dhcp-option DNS 64.6.64.6"' >> /etc/openvpn/server-common.conf
		echo 'push "dhcp-option DNS 64.6.65.6"' >> /etc/openvpn/server-common.conf
		;;
	esac
	echo "keepalive 10 120
cipher AES-256-CBC
comp-lzo
persist-key
persist-tun
verb 3
crl-verify crl.pem" >> /etc/openvpn/server-common.conf
	echo "port $PORT
proto udp
status openvpn-status.log
server 10.8.0.0 255.255.255.0
user nobody
group $GROUPNAME" > /etc/openvpn/server.conf
	cat /etc/openvpn/server-common.conf >> /etc/openvpn/server.conf
	if [[ ! -z $PORT_TCP ]]; then
		echo "port $PORT_TCP
proto tcp
status openvpn-status-tcp.log
server 10.9.0.0 255.255.255.0" > /etc/openvpn/server-tcp.conf
		if [[ $PORT_TCP -gt 1000 ]]; then
			echo "user nobody
group $GROUPNAME" > /etc/openvpn/server-tcp.conf
		fi
		cat /etc/openvpn/server-common.conf >> /etc/openvpn/server-tcp.conf
	fi
	rm /etc/openvpn/server-common.conf
	# Enable net.ipv4.ip_forward for the system
	sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
	if ! grep -q "\<net.ipv4.ip_forward\>" /etc/sysctl.conf; then
		echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
	fi
	# Avoid an unneeded reboot
	echo 1 > /proc/sys/net/ipv4/ip_forward
	# Set NAT for the VPN subnet
	iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP
	sed -i "1 a\iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP" $RCLOCAL
	[[ ! -z "$PORT_TCP" ]] && iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j SNAT --to $IP
	[[ ! -z "$PORT_TCP" ]] && sed -i "1 a\iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j SNAT --to $IP" $RCLOCAL
	if pgrep firewalld; then
		# We don't use --add-service=openvpn because that would only work with
		# the default port. Using both permanent and not permanent rules to
		# avoid a firewalld reload.
		firewall-cmd --zone=public --add-port=$PORT/udp
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		[[ ! -z "$PORT_TCP" ]] && firewall-cmd --zone=public --add-port=$PORT_TCP/tcp
		[[ ! -z "$PORT_TCP" ]] && firewall-cmd --zone=trusted --add-source=10.9.0.0/24
		firewall-cmd --permanent --zone=public --add-port=$PORT/udp
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		[[ ! -z "$PORT_TCP" ]] && firewall-cmd --permanent --zone=public --add-port=$PORT_TCP/tcp
		[[ ! -z "$PORT_TCP" ]] && firewall-cmd --permanent --zone=trusted --add-source=10.9.0.0/24
	fi
	if iptables -L -n | grep -qE 'REJECT|DROP'; then
		# If iptables has at least one REJECT rule, we asume this is needed.
		# Not the best approach but I can't think of other and this shouldn't
		# cause problems.
		iptables -I INPUT -p udp --dport $PORT -j ACCEPT
		[[ ! -z "$PORT_TCP" ]] && iptables -I INPUT -p tcp --dport $PORT_TCP -j ACCEPT
		iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
		[[ ! -z "$PORT_TCP" ]] && iptables -I FORWARD -s 10.9.0.0/24 -j ACCEPT
		iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
		sed -i "1 a\iptables -I INPUT -p udp --dport $PORT -j ACCEPT" $RCLOCAL
		[[ ! -z "$PORT_TCP" ]] && sed -i "1 a\iptables -I INPUT -p tcp --dport $PORT_TCP -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT" $RCLOCAL
		[[ ! -z "$PORT_TCP" ]] && sed -i "1 a\iptables -I FORWARD -s 10.9.0.0/24 -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" $RCLOCAL
	fi
	# If SELinux is enabled and a custom port was selected, we need this
	if hash sestatus 2>/dev/null; then
		if sestatus | grep "Current mode" | grep -qs "enforcing"; then
			if [[ "$PORT" != '1194' ]]; then
				# semanage isn't available in CentOS 6 by default
				if ! hash semanage 2>/dev/null; then
					yum install policycoreutils-python -y
				fi
				semanage port -a -t openvpn_port_t -p udp $PORT
			fi
			if [[ ! -z "$PORT_TCP" ]]; then
				# semanage isn't available in CentOS 6 by default
				if ! hash semanage 2>/dev/null; then
					yum install policycoreutils-python -y
				fi
				semanage port -a -t openvpn_port_t -p tcp $PORT_TCP
			fi
		fi
	fi
	# And finally, restart OpenVPN
	if [[ "$OS" = 'debian' ]]; then
		# Little hack to check for systemd
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
		else
			/etc/init.d/openvpn restart
		fi
	else
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
			systemctl enable openvpn@server.service
		else
			service openvpn restart
			chkconfig openvpn on
		fi
	fi
	# Try to detect a NATed connection and ask about it to potential LowEndSpirit users
	EXTERNALIP=$(wget -qO- ipv4.icanhazip.com)
	if [[ "$IP" != "$EXTERNALIP" ]]; then
		echo ""
		echo "Looks like your server is behind a NAT!"
		echo ""
		echo "If your server is NATed (e.g. LowEndSpirit), I need to know the external IP"
		echo "If that's not the case, just ignore this and leave the next field blank"
		read -p "External IP: " -e USEREXTERNALIP
		if [[ "$USEREXTERNALIP" != "" ]]; then
			IP=$USEREXTERNALIP
		fi
	fi
	# config.install is used to rebuild the server with the same pki and options.
	# IP is purposely not saved because the restored server would have a new IP address.
	echo "PORT=$PORT
PORT_TCP=$PORT_TCP
DNS=$DNS
SERVER_HOSTNAME=$SERVER_HOSTNAME" > /etc/openvpn/config.install
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
sndbuf 0
rcvbuf 0
remote $SERVER_HOSTNAME $PORT udp
remote $SERVER_HOSTNAME $PORT_TCP tcp-client
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
comp-lzo
setenv opt block-outside-dns
key-direction 1
verb 3" > /etc/openvpn/client-common.txt
	echo ""
	echo "Finished!"
	if [[ $HAS_CONFIG_DIR = '1' ]]; then
		echo ""
		echo "Your server has been restored/reconstructed from the specified directory."
	fi
	if [[ ! -z "$CLIENT" ]]; then
		# Generates the custom client.ovpn
		newclient "$CLIENT"
		echo ""
		echo "Your client configuration is available at" ~/"$CLIENT.ovpn"
		echo "If you want to add more clients, you simply need to run this script another time!"
	fi
fi
