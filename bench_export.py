import requests
from urllib import urlencode
import os

def push(results, cfg, log, version):
    """
    Push results into benchmark server
    """
    if cfg is None:
        log.info('there is no export section in config.yml')
        return
    server, key = cfg.split(':')

    if not server:
        log.info('result server is not specified in config.yml')
    if not key:
        log.info('auth key is not specified in config.yml')
    if not server or not key:
        return

    for bench_key, val in results.items():
        url = 'http://%s/push?%s' % (server, urlencode(dict(
            key=key, name='bank.%s' % bench_key, param=str(val),
            v=version, unit='sec', tab='bank'
        )))

        resp = requests.get(url)
        if resp.status_code == 200:
            log.info('pushed %s to result server' % bench_key)
        else:
            log.info(
                "can't push %s to result server: http %d",
                resp.status_code
            )
