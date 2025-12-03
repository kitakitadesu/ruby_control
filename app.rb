# typed: true

require 'sorbet-runtime'
require 'sinatra'
require 'serialport'
require 'faye/websocket'
require 'json'

class ESPNOWWebUI < Sinatra::Base
  extend T::Sig

  @@serial_port = T.let(nil, T.nilable(SerialPort))
  @@current_robot = T.let(nil, T.nilable(String))
  @@speed = T.let(50, Integer)
  @@servo1 = T.let(90, Integer)
  @@servo2 = T.let(90, Integer)
  @@pressed_keys = T.let({}, T::Hash[String, T::Boolean])
  @@ws_clients = T.let([], T::Array[Faye::WebSocket])
  @@discovered_robots = T.let({}, T::Hash[String, String])

  ROBOT_MACS = T.let({
    'RobotA' => '30:83:98:93:07:F1',
    'RobotB1' => '30:83:98:93:07:F1',
    'RobotB2' => 'ff:ff:ff:ff:ff:ff',
    'RobotC' => '77:88:99:aa:bb:cc',
    'RobotD' => 'dd:ee:ff:11:22:33'
  }, T::Hash[String, String])

  get '/' do
    erb :index
  end

  get '/ports' do
    ports = Dir.glob('/dev/cu.*')
    ports.select! { |p| File.chardev?(p) }
    options = ports.map { |p| "<option value=\"#{p}\">#{p}</option>" }.join
    options
  end

  get '/robots' do
    robots = ROBOT_MACS.merge(@@discovered_robots)
    options = robots.map { |name, mac| "<option value=\"#{name}\">#{name} (#{mac})</option>" }.join
    options
  end

  get '/ws' do
    if Faye::WebSocket.websocket?(env)
      ws = Faye::WebSocket.new(env)

      ws.on :open do
        @@ws_clients << ws
      end

      ws.on :message do |event|
        data = JSON.parse(event.data) rescue {}
        type = data['type']
        case type
        when 'keydown'
          key = data['key']
          if key == ' '
            self.class.send_stop(ws)
          else
            @@pressed_keys[key] = true
            self.class.send_command(ws)
          end
        when 'keyup'
          key = data['key']
          @@pressed_keys.delete(key)
          self.class.send_command(ws)
        when 'adjust_speed'
          direction = data['direction']
          if direction == 'up'
            @@speed += 10
            @@speed = 100 if @@speed > 100
          elsif direction == 'down'
            @@speed -= 10
            @@speed = 0 if @@speed < 0
          end
          self.class.send_command(ws) if @@pressed_keys.any?
          ws.send({type: 'speed_update', speed: @@speed}.to_json)
        when 'adjust_servo'
          servo = data['servo']
          direction = data['direction']
          if servo == 1
            @@servo1 += direction == 'up' ? 5 : -5
            @@servo1 = 0 if @@servo1 < 0
            @@servo1 = 180 if @@servo1 > 180
          elsif servo == 2
            @@servo2 += direction == 'up' ? 5 : -5
            @@servo2 = 0 if @@servo2 < 0
            @@servo2 = 180 if @@servo2 > 180
          end
          self.class.send_command(ws) if @@pressed_keys.any?
          self.class.broadcast_servo_update
        when 'set_servo'
          servo = data['servo']
          value = data['value'].to_i
          if servo == 1
            @@servo1 = value
          elsif servo == 2
            @@servo2 = value
          end
          self.class.broadcast_servo_update
        when 'stop'
          self.class.send_stop(ws)
        end
      end

      ws.on :close do
        @@ws_clients.delete(ws)
      end

      ws.rack_response
    else
      [200, {'Content-Type' => 'text/plain'}, ['WebSocket connection required']]
    end
  end

  post '/select_port' do
    port = params[:port]
    puts "DEBUG: Port received: #{port.inspect}"
    if port.nil? || port.empty?
      "Error: No port selected"
    elsif !File.exist?(port)
      "Error: Port #{port} does not exist"
    else
      begin
        @@serial_port = SerialPort.new(port, 115200)
        self.class.start_serial_reader
        "Port #{port} opened successfully"
      rescue => e
        "Error opening port: #{e.message}"
      end
    end
  end

  post '/select_robot' do
    robot = params[:robot]
    puts "DEBUG: Robot received: #{robot.inspect}"
    if robot.nil? || robot.empty?
      "Error: No robot selected"
    elsif ROBOT_MACS[robot] || @@discovered_robots[robot]
      @@current_robot = robot
      mac = ROBOT_MACS[robot] || @@discovered_robots[robot]
      "Robot #{robot} selected, MAC: #{mac}"
    else
      "Invalid robot"
    end
  end

  post '/discovery' do
    return "No port selected" unless @@serial_port
    @@serial_port.write("discovery\n")
    "Discovery sent"
  end

  post '/command' do
    return "No port selected" unless @@serial_port
    return "No robot selected" unless @@current_robot

    cmd = params[:cmd]
    speed = params[:speed] || @@speed
    @@speed = speed.to_i if speed

    mac = ROBOT_MACS[@@current_robot] || @@discovered_robots[@@current_robot]
    full_cmd = "[#{mac}]#{cmd} #{speed} #{@@servo1} #{@@servo2}\n"
    @@serial_port.write(full_cmd)
    "Sent: #{full_cmd.strip}"
  end

  post '/adjust_speed' do
    direction = params[:direction]
    if direction == 'up'
      @@speed += 10
      @@speed = 100 if @@speed > 100
    elsif direction == 'down'
      @@speed -= 10
      @@speed = 0 if @@speed < 0
    end
    @@speed.to_s
  end

  sig { params(ws: Faye::WebSocket).void }
  def self.send_command(ws)
    return unless @@serial_port && @@current_robot

    if @@pressed_keys.empty?
      cmd = ''
      speed = 0
    else
      cmd = ''
      cmd += 'f' if @@pressed_keys['w']
      cmd += 'b' if @@pressed_keys['s']
      cmd += 'l' if @@pressed_keys['a']
      cmd += 'r' if @@pressed_keys['d']
      cmd += 'ql' if @@pressed_keys['q']
      cmd += 'qr' if @@pressed_keys['e']
      speed = @@speed
    end

    mac = T.must(ROBOT_MACS[@@current_robot] || @@discovered_robots[@@current_robot])
    full_cmd = "[#{mac}]#{cmd} #{speed} #{@@servo1} #{@@servo2}\n"
    T.must(@@serial_port).write(full_cmd)
    ws.send({type: 'status', message: "Sent: #{full_cmd.strip}"}.to_json)
  end

  sig { params(ws: Faye::WebSocket).void }
  def self.send_stop(ws)
    return unless @@serial_port && @@current_robot

    @@pressed_keys.clear
    mac = T.must(ROBOT_MACS[@@current_robot] || @@discovered_robots[@@current_robot])
    full_cmd = "[#{mac}] 0 #{@@servo1} #{@@servo2}\n"
    T.must(@@serial_port).write(full_cmd)
    ws.send({type: 'status', message: "Sent: #{full_cmd.strip}"}.to_json)
  end

  def self.broadcast_servo_update
    @@ws_clients.each do |ws|
      ws.send({type: 'servo_update', servo1: @@servo1, servo2: @@servo2}.to_json)
    end
  end

  def self.start_serial_reader
    Thread.new do
      loop do
        if @@serial_port
          data = @@serial_port.read(100) rescue nil
          puts "DEBUG: Serial read: #{data.inspect}" if data
          if data && !data.empty?
            if data.strip =~ /^Discovery reply: (\w+) (.+)$/
              name = $1
              mac = $2
              @@discovered_robots[name] = mac
            end
            timestamp = Time.now.strftime("%H:%M:%S")
            message = "#{timestamp}: #{data.strip}"
            puts "DEBUG: Broadcasting serial: #{message}"
            @@ws_clients.each do |ws|
              ws.send({type: 'serial_output', message: message}.to_json)
            end
          end
        end
        sleep 0.1
      end
    end
  end
end

if __FILE__ == $0
  ESPNOWWebUI.run!
end
