# simple_writer_image/Dockerfile
FROM alpine:latest

# Install bash for the entrypoint script (alpine uses 'ash' by default, bash is more common for scripts)
# Install coreutils for 'tail' and 'mv' commands used in the entrypoint
RUN apk add --no-cache bash coreutils

# Set working directory (not strictly necessary for this simple writer, but good practice)
WORKDIR /data

# Copy the entrypoint script into the image
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the entrypoint for the container
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
