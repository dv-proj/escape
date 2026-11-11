FROM nginx:1.30-alpine
RUN apk add --no-cache openssl \
    && rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
COPY fakeapp.conf /etc/nginx/snippets/fakeapp.conf
COPY --chmod=755 entrypoint.sh /usr/local/bin/tls-entrypoint.sh
EXPOSE 80 443
ENTRYPOINT ["/usr/local/bin/tls-entrypoint.sh"]
