require "kemal"
require "calcium"
require "multiset"
require "crirc"

require "./mjirandom"

module Numbersgame
  VERSION = "0.1.0"

  class_getter games = {} of String => Game

  class IrcConnection
    @@nick = ENV["NWS_USERNAME"]
    @@addr = "irc.chat.twitch.tv"
    @@port = 6697_u16

    getter bot : Crirc::Controller::Client

    def initialize()
      # Connect to IRC
      client = Crirc::Network::Client.new(nick: @@nick, ip: @@addr, port: @@port,
                                          user: @@nick, ssl: true)
      client.connect
      client.puts("PASS #{ENV["NWS_OAUTH"]}")
      @bot = client.start do |bot|
        bot.on("PRIVMSG") do |msg|
          handle_message(msg.arguments, msg.source, msg.message)
        end

        spawn do
          loop do
            begin
              m = bot.gets
              break if m.nil?
              puts "IRC: [#{Time.utc}] #{m}"
              spawn { bot.handle(m.as(String)) }
            rescue IO::TimeoutError
              puts "IRC: Nothing happened..."
            end
          end
        end
        bot
      end
    end

    def join(channel : String)
      @bot.join Crirc::Protocol::Chan.new(channel.downcase)
    end

    def leave(channel : String)
      @bot.part Crirc::Protocol::Chan.new(channel.downcase)
    end

    def handle_message(channel, sender, msg)
      return if channel.nil?
      return if msg.nil?

      # Message looks like it could be a valid guess
      if md = msg.match(/(?<guess>\A[\d\s\*\+\-\/\(\)\!\^]+)/)
        gamehost = channel.gsub('#', "")
        guesser = sender.split('!')[0]
        puts "IRC: ##{gamehost}: #{guesser} guessed #{msg}"
        game = Numbersgame.games[gamehost]?
        game.submit_guess(guesser, md["guess"]) unless game.nil?
      end
    end
  end


  class Game
    @@tolerance = 0.05  # How much a guess can be off from nearest whole number and still be rounded
    @@irc = IrcConnection.new
    alias Guess = NamedTuple(user: String, guess: String, result: String, hit: Bool)

    getter username : String
    getter timer : Int32
    getter level : Int32
    getter targets : Array(Int32)
    getter remaining : Array(Int32)
    getter numbers : Multiset(Int32)
    getter guesses : Array(Guess)

    def initialize(username)
      @username = username
      @level = 1
      @timer = 30
      @stopped = false  # when true timer will stop running TODO: should be true to begin with
      @numbers = get_numbers(1)
      @targets = get_targets(1)
      @remaining = @targets.clone
      @guesses = [] of Guess
      @sockets = [] of HTTP::WebSocket
      @@irc.join("##{username}")
      level_begin
    end

    def add_socket(socket : HTTP::WebSocket)
      @sockets << socket
    end

    def broadcast(msg : String, silent=false)
      puts "WS-BROADCAST: #{msg}" unless silent
      @sockets.each do |socket|
        socket.send msg
      end
    end

    def corrects()
      @targets.size - @remaining.size
    end

    def delete_socket(socket : HTTP::WebSocket)
      @sockets.delete socket
    end

    def get_numbers(level : Int32)
      Multiset.new (
        Mjirandom.sample(1, 9, 2) +
        Mjirandom.sample(1, 9, 2) +
        [10, 20, 25, 50, 75, 100].sample(2) +
        Mjirandom.sample(1, 150, 1)
      )
    end

    def get_targets(level : Int32)
      return Mjirandom.sample(101, 400+100*level, 7+level).sort
    end

    def is_valid?(guess : String)
      return false unless /\A[\d\s\*\+\-\/\(\)\!\^]+\Z/.match(guess)
      begin
        tokens = Calcium.tokenize(guess).select!{ |x| x.is_a?(Calcium::NumberToken) }
        used = Multiset(Int32).new
        tokens.each do |x|
          used << x.value.to_i
        end
        return false unless used.subset?(@numbers)
      rescue ex
        puts ex.message
        return false
      end

      return true
    end

    def level_begin()
      @numbers = get_numbers(@level)
      @targets = get_targets(@level)
      @remaining = @targets.clone
      @guesses = [] of Guess
      puts "Starting level #{@level} with targets #{@targets.to_s}"
      broadcast("STATUS #{corrects()}/#{required()}")
      start_timer(120)
    end

    def level_completed()
      corrects() >= required()
    end

    def level_end()
      @stopped = true
      unless level_completed
        broadcast("GAMEOVER")
        @@irc.leave("##{@username}")
        Numbersgame.games.delete(username.downcase)
      end
    end

    def level_next()
      if level_completed
        @level += 1
        level_begin()
      end
    end

    def required()
      @targets.size-3
    end

    def start_timer(seconds : Int32)
      @timer = seconds
      @stopped = false
      spawn do
        loop do
          broadcast("TIMER #{@timer}", silent=true)
          if @timer == 0
            @stopped = true
            level_end
            break
          end
          sleep 1
          break if @stopped
          @timer -= 1
        end
      end
    end

    def submit_guess(guesser : String, guess : String)
      return if @stopped
      return unless is_valid?(guess)

      begin
        result = Calcium.calculate(guess)
        rounded = (result+0.5).to_i
        result = rounded if (result - rounded).abs < @@tolerance
      rescue ex
        puts ex.message
        result = "ERROR"
      end

      hit = false
      if @remaining.includes?(result)
        hit = true
        @remaining.delete result
        broadcast("STATUS #{corrects()}/#{required()}")
      end
      guessed = {user: guesser, guess: guess, result: result.to_s, hit: hit}
      @guesses << guessed
      broadcast "GUESSED #{guessed.to_json}"
    end
  end



  get "/" do
    render "src/views/index.ecr", "src/views/layout.ecr"
  end

  post "/startgame" do |env|
    username = env.params.body["username"].as(String)
    @@games[username.downcase] = Game.new(username) unless @@games.has_key?(username.downcase)
    env.redirect "/game/#{username.downcase}"
  end

  # Viewing a game
  get "/game/:username" do |env|
    username = env.params.url["username"].downcase
    if @@games.has_key?(username)
      game = @@games[username]
      render "src/views/game.ecr", "src/views/layout.ecr"
    else
      error = "No game found"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  # TODO: authentication
  post "/game/:username/next" do |env|
    username = env.params.url["username"].as(String)
    if @@games.has_key?(username)
      @@games[username].level_next()
    end
    env.redirect "/game/#{username.downcase}"
  end

  ws "/game/:username" do |socket, context|
    username = context.ws_route_lookup.params["username"].downcase
    next unless @@games.has_key?(username)
    puts "WS: Opened socket #{socket} (#{username})"

    game = @@games[username]
    game.add_socket socket
    socket.send "ALLGUESSES #{game.guesses.to_json}"
    socket.send "TIMER #{game.timer}"
    socket.send "STATUS #{game.corrects}/#{game.required}"

    # Listen to messages
    socket.on_message do |message|
      case
      # Making a guess via websocket
      when /GUESS [^ ]+ [^ ]/.match(message)
        parts = message.split(3)
        game.submit_guess(parts[1], parts[2])
      end
    end

    socket.on_close do
      puts "WS: Closed socket #{socket} (#{username})"
      game.delete_socket socket
    end
  end

  Kemal.run

end
