FROM ghcr.io/adsblol/api:latest

ENV MY_DOMAIN=my.bharat-radar.vellur.in

COPY patch.py /tmp/patch.py
RUN python3 /tmp/patch.py && rm /tmp/patch.py
