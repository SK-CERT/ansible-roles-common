#! /bin/sh
#
# {{ ansible_managed }}
#
{%- macro normalize_addrs(rule, attr) -%}
{% set results = [] %}
{% if attr in rule %}
{% set attrs = ( rule[attr].replace(' ','').split(',') if rule[attr] is string else rule[attr] ) %}
{% for name_or_addr in attrs %}
{% if name_or_addr in firewall_objects %}
{% set xaddr = firewall_objects[name_or_addr] %}
{% do results.append(xaddr.replace(' ','').split(',') if xaddr is string else xaddr) %}
{% else %}
{% do results.append([name_or_addr]) %}
{% endif %}
{% endfor %}
{% endif %}
{{ results | flatten | join(",") }}
{%- endmacro -%}

{%- macro normalize_addrs6(rule, attr) -%}
{% set results = [] %}
{% if attr in rule %}
{% set attrs = ( rule[attr].replace(' ','').split(',') if rule[attr] is string else rule[attr] ) %}
{% for name_or_addr in attrs %}
{% if name_or_addr in firewall6_objects %}
{% set xaddr = firewall6_objects[name_or_addr] %}
{% do results.append(xaddr.replace(' ','').split(',') if xaddr is string else xaddr) %}
{% else %}
{% do results.append([name_or_addr]) %}
{% endif %}
{% endfor %}
{% endif %}
{{ results | flatten | join(",") }}
{%- endmacro -%}

{%- macro normalize_ports(rule, proto) -%}
{%- if 'proto' in rule -%}
{%- if proto in rule.proto -%}
{{ ( rule.proto[proto].replace(' ','').split(',') if rule.proto[proto] is string else ( [rule.proto[proto]] if rule.proto[proto] is number else rule.proto[proto] ) ) | join(",") }}
{%- endif -%}
{%- endif -%}
{%- endmacro -%}
#
# Simple iptables management script (fw.sh)

### BEGIN INIT INFO
# Provides:          fw.sh
# Required-Start:    $local_fs $network
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: fw.sh
# Description:       firewall
### END INIT INFO

IT4=/sbin/iptables
IT6=/sbin/ip6tables

modprobe ip_conntrack
modprobe ip_conntrack_ftp

echo {{ firewall_ip_forward | default(0) | int }} > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv4/tcp_syncookies
echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter
echo {{ firewall_log_martians | default(1) | int }} > /proc/sys/net/ipv4/conf/all/log_martians
echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_broadcasts
echo 1 > /proc/sys/net/ipv4/icmp_ignore_bogus_error_responses
echo 0 > /proc/sys/net/ipv4/conf/all/send_redirects
echo 0 > /proc/sys/net/ipv4/conf/all/accept_source_route

for PROTO in 4 6; do
  IT=$( eval echo \$IT$PROTO )
  X=$( [ $PROTO -eq 6 ] && echo "6" )

  # flush tables
  for TABLE in filter nat mangle; do
    $IT -t $TABLE -F
    $IT -t $TABLE -X
  done

  # default rulesets
  $IT -P INPUT DROP
  $IT -P OUTPUT DROP
  $IT -P FORWARD DROP

  # custom REJECT action with logging
  $IT -N LOG_REJECT
    $IT -A LOG_REJECT -m limit --limit 10/sec --limit-burst 20 -j LOG \
      --log-ip-options --log-tcp-options --log-uid \
      --log-prefix "FW${PROTO}-REJECT " --log-level info
    $IT -A LOG_REJECT -m limit --limit 10/sec --limit-burst 20 -j REJECT \
      --reject-with icmp$X-port-unreachable
    $IT -A LOG_REJECT -j DROP

  # custom DROP action with logging
  $IT -N LOG_DROP
    $IT -A LOG_DROP -m limit --limit 10/sec --limit-burst 20 -j LOG \
      --log-ip-options --log-tcp-options --log-uid \
      --log-prefix "FW${PROTO}-DROP " --log-level info
    $IT -A LOG_DROP -j DROP

  # custom ACCEPT action with logging
  $IT -N LOG_ACCEPT
    $IT -A LOG_ACCEPT -m limit --limit 50/sec --limit-burst 100 -j LOG \
      --log-ip-options --log-tcp-options --log-uid \
      --log-prefix "FW${PROTO}-ACCEPT " --log-level info
    $IT -A LOG_ACCEPT -j ACCEPT

  # custom ACCEPT action with logging
  $IT -N LOG_WILL_DROP
    $IT -A LOG_WILL_DROP -m limit --limit 50/sec --limit-burst 100 -j LOG \
      --log-ip-options --log-tcp-options --log-uid \
      --log-prefix "FW${PROTO}-WILL-DROP " --log-level info
    $IT -A LOG_WILL_DROP -j ACCEPT

done
IT=""


############################################################
### verify source address of packet (RFC 2827, RFC 1918)

$IT4 -N CHECK_IF
  # allow dhcp on specific interfaces
{% for firewall_iface_name, firewall_iface in firewall_interfaces.items() %}
{% if firewall_iface.allow_dhcp | default(false) %}
  $IT4 -A CHECK_IF -i {{ firewall_iface_name }} -s 0.0.0.0 -j RETURN # DHCP
{% endif %}
{% endfor %}

  # multicast shit...
  $IT4 -A CHECK_IF -s 0.0.0.0/8 -d 224.0.0.1 -p 2 -j DROP #IGMP

  # no-one can send from special address ranges!
  $IT4 -A CHECK_IF -s 127.0.0.0/8 -j LOG_DROP     # loopback
  $IT4 -A CHECK_IF -s 0.0.0.0/8 -j LOG_DROP       # DHCP
  $IT4 -A CHECK_IF -s 169.254.0.0/16 -j DROP      # APIPA
  $IT4 -A CHECK_IF -s 192.0.2.0/24 -j LOG_DROP    # RFC 3330
  $IT4 -A CHECK_IF -s 204.152.64.0/23 -j LOG_DROP # RFC 3330
  $IT4 -A CHECK_IF -s 224.0.0.0/3 -j DROP         # multicast

  # interface specific configuration
{% for firewall_iface_name, firewall_iface in firewall_interfaces.items() %}
{% with %}
{% set allow_nets = normalize_addrs(firewall_iface, 'allow').split(',') | difference(['']) %}
{% set deny_nets = normalize_addrs(firewall_iface, 'deny').split(',') | difference(['']) %}
{% for allow_net in allow_nets %}
  $IT4 -A CHECK_IF -i {{ firewall_iface_name }} -s {{ allow_net }} -j RETURN
{% endfor %}
{% for deny_net in deny_nets %}
  $IT4 -A CHECK_IF -i {{ firewall_iface_name }} -s {{ deny_net }} -j LOG_DROP
{% endfor %}
{% if firewall_iface.default | default('allow' if firewall_interfaces|length == 1 else 'deny') == 'allow' %}
  $IT4 -A CHECK_IF -i {{ firewall_iface_name }} -j RETURN
{% else %}
  $IT4 -A CHECK_IF -i {{ firewall_iface_name }} -j LOG_DROP
{% endif %}
{% endwith %}
{% endfor %}

  # everything else is dropped!
  $IT4 -A CHECK_IF -j LOG_DROP

$IT6 -N CHECK_IF
  # disable IPv6 source routing (and ping-pong)
  $IT6 -A CHECK_IF -m rt --rt-type 0 -j LOG_DROP

  #XXX:
  # per interface filter
  $IT6 -A CHECK_IF -j RETURN

  $IT6 -A CHECK_IF -j LOG_DROP


############################################################
### allow loopbacks, check origin, and related/established

# everything is allowed on loopback
$IT4 -A INPUT -i lo -j ACCEPT
$IT6 -A INPUT -i lo -j ACCEPT

# check for spoofed addresses
for CHAIN in INPUT FORWARD; do
  $IT4 -A $CHAIN -j CHECK_IF
  $IT6 -A $CHAIN -j CHECK_IF
done

# connection tracking:
# - allow all related/established traffic
# - invalid packets MUST be dropped!
for CHAIN in INPUT FORWARD OUTPUT; do
  $IT4 -A $CHAIN -m state --state ESTABLISHED,RELATED -j ACCEPT
  $IT4 -A $CHAIN -m state --state INVALID -j LOG_DROP
  $IT6 -A $CHAIN -m state --state ESTABLISHED,RELATED -j ACCEPT
  $IT6 -A $CHAIN -m state --state INVALID -j LOG_DROP
done

# IPv6 service ICMPs (router advertisements, etc)
for TYPE in 133 134 135 136 137 ; do
  $IT6 -A INPUT -p ipv6-icmp --icmpv6-type $TYPE -m hl --hl-eq 255 -j ACCEPT
  $IT6 -A OUTPUT -p ipv6-icmp --icmpv6-type $TYPE -m hl --hl-eq 255 -j ACCEPT
done

# multicast ipcmv6 shit...
$IT6 -A INPUT -p ipv6-icmp --icmpv6-type 130 -d ff02::1 -j DROP
$IT6 -A OUTPUT -p ipv6-icmp --icmpv6-type 143 -d ff02::16 -j DROP

############################################################
### INPUT ruleset

{% for input_rule_name,input_rule in firewall_input.items() %}
{% with %}
	{% set src_addrs = normalize_addrs(input_rule, 'src').split(',') %}
	{% set dest_addrs = normalize_addrs(input_rule, 'dest').split(',') %}
	{% set tcp_ports = normalize_ports(input_rule, 'tcp').split(',') | difference(['']) %}
	{% set udp_ports = normalize_ports(input_rule, 'udp').split(',') | difference(['']) %}

# {{ input_rule_name }}
# {{ input_rule | to_json }}
{% for src_addr in src_addrs -%}
{%- for dest_addr in dest_addrs -%}
{% for port in tcp_ports | list %}
$IT4 -A INPUT -p tcp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ input_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in udp_ports | list %}
$IT4 -A INPUT -p udp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ input_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for proto in input_rule.proto.other | default([]) %}
$IT4 -A INPUT -p {{ proto }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ input_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{%- endfor -%}
{%- endfor -%}

{% endwith %}
{% endfor %}


{% for input_rule_name,input_rule in firewall6_input.items() %}
{% with %}
	{% set src_addrs = normalize_addrs6(input_rule, 'src').split(',') %}
	{% set dest_addrs = normalize_addrs6(input_rule, 'dest').split(',') %}
	{% set tcp_ports = normalize_ports(input_rule, 'tcp').split(',') | difference(['']) %}
	{% set udp_ports = normalize_ports(input_rule, 'udp').split(',') | difference(['']) %}

# {{ input_rule_name }}
# {{ input_rule | to_json }}
{% for src_addr in src_addrs -%}
{%- for dest_addr in dest_addrs -%}
{% for port in tcp_ports | list %}
$IT6 -A INPUT -p tcp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ input_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in udp_ports | list %}
$IT6 -A INPUT -p udp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ input_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for proto in input_rule.proto.other | default([]) %}
$IT6 -A INPUT -p {{ proto }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ input_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{%- endfor -%}
{%- endfor -%}

{% endwith %}
{% endfor %}


# IPv4 ICMP rate limit
$IT4 -A INPUT -p icmp -m limit --limit 20/second -j ACCEPT
$IT4 -A INPUT -p icmp -j LOG_DROP

# IPv6 rate limit
$IT6 -A INPUT -p ipv6-icmp --icmpv6-type 128 -m limit --limit 20/s -j ACCEPT
$IT6 -A INPUT -p icmp -j LOG_DROP

# ignore broadcasts
$IT4 -A INPUT -m addrtype --dst-type BROADCAST -j DROP

# ignore junk from windows servers (samba)
for PORT in 137 138; do
  $IT4 -A INPUT -p udp --dport $PORT -j DROP
done

# default rule is
$IT4 -A INPUT -j {{ firewall_default_rule_input }}
$IT6 -A INPUT -j {{ firewall_default_rule_input }}


############################################################
### OUTPUT ruleset

$IT4 -A OUTPUT -o lo -j ACCEPT
$IT6 -A OUTPUT -o lo -j ACCEPT

# root can do anything
#$IT4 -A OUTPUT -m owner --uid-owner 0 -j LOG_WILL_DROP
#$IT6 -A OUTPUT -m owner --uid-owner 0 -j LOG_WILL_DROP

# _apt
#$IT4 -A OUTPUT -m owner --uid-owner 105 -j ACCEPT
#$IT4 -A OUTPUT -m owner --uid-owner 104 -j ACCEPT
#$IT6 -A OUTPUT -m owner --uid-owner 105 -j ACCEPT
#$IT6 -A OUTPUT -m owner --uid-owner 104 -j ACCEPT

# DNS
$IT4 -A OUTPUT -p udp --dport 53 -j LOG_ACCEPT
$IT6 -A OUTPUT -p udp --dport 53 -j LOG_ACCEPT

{% for output_rule_name,output_rule in firewall_output.items() %}
{% with %}
	{% set src_addrs = normalize_addrs(output_rule, 'src').split(',') %}
	{% set dest_addrs = normalize_addrs(output_rule, 'dest').split(',') %}
	{% set tcp_ports = normalize_ports(output_rule, 'tcp').split(',') | difference(['']) %}
	{% set udp_ports = normalize_ports(output_rule, 'udp').split(',') | difference(['']) %}

# {{ output_rule_name }}
# {{ output_rule | to_json }}
{% for src_addr in src_addrs -%}
{%- for dest_addr in dest_addrs -%}
{% for port in tcp_ports | list %}
$IT4 -A OUTPUT -p tcp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ output_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in udp_ports | list %}
$IT4 -A OUTPUT -p udp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ output_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for proto in output_rule.proto.other | default([]) %}
$IT4 -A OUTPUT -p {{ proto }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ output_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{%- endfor -%}
{%- endfor -%}

{% endwith %}
{% endfor %}

{% for output_rule_name,output_rule in firewall6_output.items() %}
{% with %}
	{% set src_addrs = normalize_addrs6(output_rule, 'src').split(',') %}
	{% set dest_addrs = normalize_addrs6(output_rule, 'dest').split(',') %}
	{% set tcp_ports = normalize_ports(output_rule, 'tcp').split(',') | difference(['']) %}
	{% set udp_ports = normalize_ports(output_rule, 'udp').split(',') | difference(['']) %}

# {{ output_rule_name }}
# {{ output_rule | to_json }}
{% for src_addr in src_addrs -%}
{%- for dest_addr in dest_addrs -%}
{% for port in tcp_ports | list %}
$IT6 -A OUTPUT -p tcp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ output_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in udp_ports | list %}
$IT6 -A OUTPUT -p udp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ output_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for proto in output_rule.proto.other | default([]) %}
$IT6 -A OUTPUT -p {{ proto }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ output_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{%- endfor -%}
{%- endfor -%}

{% endwith %}
{% endfor %}


# default to drop
$IT4 -A OUTPUT -j {{ firewall_default_rule_output }}
$IT6 -A OUTPUT -j {{ firewall_default_rule_output }}


############################################################
### FORWARD ruleset

{% for forward_rule_name,forward_rule in firewall_forward.items() %}
{% with %}
	{% set src_addrs = normalize_addrs(forward_rule, 'src').split(',') %}
	{% set dest_addrs = normalize_addrs(forward_rule, 'dest').split(',') %}
	{% set tcp_ports = normalize_ports(forward_rule, 'tcp').split(',') | difference(['']) %}
	{% set udp_ports = normalize_ports(forward_rule, 'udp').split(',') | difference(['']) %}
	{% set sctp_ports = normalize_ports(forward_rule, 'sctp').split(',') | difference(['']) %}

# {{ forward_rule_name }}
# {{ forward_rule | to_json }}
{% for src_addr in src_addrs -%}
{%- for dest_addr in dest_addrs -%}
{% for port in tcp_ports | list %}
$IT4 -A FORWARD -p tcp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in udp_ports | list %}
$IT4 -A FORWARD -p udp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in sctp_ports | list %}
$IT4 -A FORWARD -p sctp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% if tcp_ports == [] and udp_ports == [] and sctp_ports == [] %}
$IT4 -A FORWARD {{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endif %}
{%- endfor -%}
{%- endfor -%}

{% endwith %}
{% endfor %}

{% for forward_rule_name,forward_rule in firewall6_forward.items() %}
{% with %}
	{% set src_addrs = normalize_addrs6(forward_rule, 'src').split(',') %}
	{% set dest_addrs = normalize_addrs6(forward_rule, 'dest').split(',') %}
	{% set tcp_ports = normalize_ports(forward_rule, 'tcp').split(',') | difference(['']) %}
	{% set udp_ports = normalize_ports(forward_rule, 'udp').split(',') | difference(['']) %}
	{% set sctp_ports = normalize_ports(forward_rule, 'sctp').split(',') | difference(['']) %}

# {{ forward_rule_name }}
# {{ forward_rule | to_json }}
{% for src_addr in src_addrs -%}
{%- for dest_addr in dest_addrs -%}
{% for port in tcp_ports | list %}
$IT6 -A FORWARD -p tcp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in udp_ports | list %}
$IT6 -A FORWARD -p udp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% for port in sctp_ports | list %}
$IT6 -A FORWARD -p sctp --dport {{ port }}{{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endfor %}
{% if tcp_ports == [] and udp_ports == [] and sctp_ports == [] %}
$IT6 -A FORWARD {{ " -s "+src_addr if src_addr|length else "" }}{{ " -d "+dest_addr if dest_addr|length else "" }} -j {{ forward_rule.rule | default('LOG_ACCEPT') }}
{% endif %}
{%- endfor -%}
{%- endfor -%}

{% endwith %}
{% endfor %}

$IT4 -A FORWARD -j {{ firewall_default_rule_forward }}
$IT6 -A FORWARD -j {{ firewall_default_rule_forward }}


############################################################
### NAT ruleset

############################################################
### custom firewall patches

{% if firewall_final_patch is defined %}
{% for rule in firewall_final_patch %}
{{rule}}
{% endfor %}
{% endif %}


############################################################

### fail2ban integration
[ -f /etc/init.d/fail2ban ] && /etc/init.d/fail2ban restart


