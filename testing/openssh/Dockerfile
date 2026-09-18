# A real OpenSSH server for interop tests.
#
# The in-process fake in tests/support speaks russh on both sides, which proves
# our client against a controlled peer but not against the software people
# actually run. This image is that check.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

RUN useradd -m -s /bin/sh scientist \
 && useradd -m -s /bin/sh twofactor \
 && printf 'scientist:correct horse\ntwofactor:correct horse\n' | chpasswd

COPY authorized_keys /home/twofactor/.ssh/authorized_keys
RUN chown -R twofactor:twofactor /home/twofactor/.ssh \
 && chmod 700 /home/twofactor/.ssh \
 && chmod 600 /home/twofactor/.ssh/authorized_keys

COPY sshd_config /etc/ssh/sshd_config

# Generated at build time: interop tests assert the shape of a fingerprint,
# never a particular one.
RUN ssh-keygen -A

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
