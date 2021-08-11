#!/bin/bash
ip=$(ip a | grep inet | awk '{print$2}' | grep -E "/23|/24|/25" | rev | cut -c4- | rev)
pass=$(openssl rand -base64 12)

apt install strongswan strongswan-pki -y 

#Создание центра сертификации и генерация ключа
mkdir -p ~/pki/{cacerts,certs,private}
chmod 700 ~/pki
ipsec pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/ca-key.pem
ipsec pki --self --ca --lifetime 3650 --in ~/pki/private/ca-key.pem --type rsa --dn "CN=VPN root CA" --outform pem > ~/pki/cacerts/ca-cert.pem
ipsec pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/server-key.pem
echo $ip | xargs -I % -n1 echo 'ipsec pki --pub --in ~/pki/private/server-key.pem --type rsa | ipsec pki --issue --lifetime 1825 --cacert ~/pki/cacerts/ca-cert.pem --cakey ~/pki/private/ca-key.pem --dn "CN=%" --san "%" --flag serverAuth --flag ikeIntermediate --outform pem > ~/pki/certs/server-cert.pem' | bash -s

cp -r ~/pki/* /etc/ipsec.d/
mv /etc/ipsec.conf{,.original}

#Создание базового конфига
echo 'config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any' > /etc/ipsec.conf
    echo '    leftid='$ip >> /etc/ipsec.conf
	echo '    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=10.10.10.0/24
    rightdns=8.8.8.8,8.8.4.4
    rightsendcert=never
    eap_identity=%identity
' >> /etc/ipsec.conf

#Создание юзера
echo ': RSA "server-key.pem"' >> /etc/ipsec.secrets
echo 'user1 : EAP "'$pass'"' >> /etc/ipsec.secrets
sudo systemctl restart strongswan

#Настройка iptables
ufw allow OpenSSH
ufw enable
ufw allow 500,4500/udp

echo -e '*nat
-A POSTROUTING -s 10.10.10.0/24 -o eth0 -m policy --pol ipsec --dir out -j ACCEPT
-A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
COMMIT
*mangle
-A FORWARD --match policy --pol ipsec --dir in -s 10.10.10.0/24 -o eth0 -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360
COMMIT\n' > temp.txt
sed -i -f - /etc/ufw/before.rules < <(sed 's/^/1i/' temp.txt)
rm temp.txt

sed -i '/End required lines/a -A ufw-before-forward --match policy --pol ipsec --dir in --proto esp -s 10.10.10.0/24 -j ACCEPT\n-A ufw-before-forward --match policy --pol ipsec --dir out --proto esp -d 10.10.10.0/24 -j ACCEPT' /etc/ufw/before.rules

sed -i 's/^#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/g' /etc/ufw/sysctl.conf
echo net/ipv4/conf/all/send_redirects=0 >> /etc/ufw/sysctl.conf
echo net/ipv4/ip_no_pmtu_disc=1 >> /etc/ufw/sysctl.conf

#Перезапуск UFW для применения правил
ufw disable
ufw enable

cert=$(cat /etc/ipsec.d/cacerts/ca-cert.pem | curl -F "sprunge=<-" http://sprunge.us)

echo -e '\n\n\n'
echo VPN setup is successfully completed!
echo 'IP: '$ip
echo Login: user1
echo 'Password: '$pass
echo 'CA Cert: '$cert
