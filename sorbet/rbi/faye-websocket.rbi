module Faye
  class WebSocket
    def self.websocket?(env); end
    def initialize(env); end
    def on(event, &block); end
    def send(data); end
    attr_reader :rack_response
  end
end