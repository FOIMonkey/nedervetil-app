ARG RUBY_VERSION=3.4.13
FROM ruby:${RUBY_VERSION}-trixie

ENV DOCKER=1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get install -y postgresql-common && \
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

RUN apt-get update -y && \
    apt-get install -y \
    bubblewrap \
    chromium \
    elinks \
    fonts-urw-base35 \
    imagemagick \
    libemail-address-perl \
    libemail-outlook-message-perl \
    libreoffice-calc-nogui \
    libreoffice-impress-nogui \
    libreoffice-writer-nogui \
    pdftk-java \
    poppler-utils \
    postgresql-client-18 \
    qpdf \
    sendmail \
    tesseract-ocr \
    tesseract-ocr-eng \
    tesseract-ocr-osd \
    tnef \
    wait-for-it \
    mutt && \
    rm -rf /var/lib/apt/lists/*

COPY lib/alaveteli_sandbox/imagemagick-policy.xml /etc/ImageMagick-7/policy.xml

WORKDIR /alaveteli
RUN git config --global --add safe.directory /alaveteli

EXPOSE 3000
CMD ["wait-for-it", "db:5432", "--strict", "--", "./docker/entrypoint.sh"]
