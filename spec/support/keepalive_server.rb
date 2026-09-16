# frozen_string_literal: true

require "socket"
require "json"

# A minimal HTTP/1.1 keep-alive server on 127.0.0.1 that answers every request
# with a JSON:API-shaped 200 and counts accept()s. One accept == one TCP
# socket, so `accepts` is a direct measure of whether a client reused its
# connection or silently re-opened one — the thing worker affinity rests on.
class KeepaliveServer
  attr_reader :port, :accepts

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @accepts = 0
    @acceptor = Thread.new { accept_loop }
  end

  def site
    "http://127.0.0.1:#{port}/api/"
  end

  def close
    @acceptor.kill
    @server.close
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      @accepts += 1
      Thread.new(sock) { |s| serve(s) }
    end
  end

  def serve(sock)
    loop do
      break unless sock.gets # request line
      headers = {}
      while (line = sock.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip
      end
      sock.read(headers["content-length"].to_i) if headers["content-length"]
      body = { data: { type: "widgets", id: "1", attributes: {} } }.to_json
      sock.write(
        "HTTP/1.1 200 OK\r\n" \
        "Content-Type: application/vnd.api+json\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: keep-alive\r\n\r\n#{body}"
      )
    end
  rescue IOError, SystemCallError
    nil
  ensure
    sock.close rescue nil
  end
end
