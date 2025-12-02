module Sinatra
  class Base
    def self.get(path, &block); end
    def self.post(path, &block); end
    def self.set(key, value); end
    def erb(template); end
    def params; end
    def env; end
    def self.run!; end
  end
end

class SerialPort
  NONE = T.let(0, Integer)

  def initialize(port, baud, data_bits, stop_bits, parity); end
  def write(data); end
end

module Faye
  class WebSocket
    def self.websocket?(env); end
    def initialize(env); end
    def on(event, &block); end
    def send(data); end
    attr_reader :rack_response
  end
end