#!/bin/sh

cd $(dirname $(readlink -f $0))

ping 10.50.10.254 -c 1

CMD="java -jar ./imdgtest-client-1.0-SNAPSHOT.jar -id {{ client_id }}"
CMD="${CMD} -switch-server-on-http-error -socketTimeout 5000 -server-retries 2 -http-retries 10"
{% for host in groups['tarantool_containers'] %}
CMD="${CMD} -server {{ hostvars[host]['ansible_ssh_host'] }}:{{ hostvars[host]['http_port'] }}"
{% endfor %}

case "$1" in
	load)
		${CMD} load -batch 100000 accounts.tsv
                ;;
	save)
		${CMD} save -out accounts_out.tsv
		;;
	trans)
		${CMD} exec-trans -batch 1 transactions.tsv
		;;
	*)
		echo "Usage: $0 load|save|trans"
		;;
esac

# vim: ts=8:sw=8:sts=8:noet
