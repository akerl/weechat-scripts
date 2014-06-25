# pushover.rb
# rubocop:disable Style/LineLength, Style/GlobalVars
#
# Copyright (c) 2014 Les Aker <me@lesaker.org>

# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# Changelog:
#   0.0.1 - Initial functionality

require 'net/https'

DEFAULTS = {
  userkey: nil,
  appkey: nil,
  devicename: nil,
  interval: '10', # seconds
  pm_priority: '1',
  hilight_priority: '1',
  onlywhenaway: '0',
  enabled: '1'
}
URL = URI.parse('https://api.pushover.net/1/messages.json')

##
# API rate limit calculator
class RateCalc
  def initialize(resp, interval)
    seconds_left = resp['X-Limit-App-Reset'].to_i - Time.now.to_i
    @potential = seconds_left / interval.to_i
    @remaining = resp['X-Limit-App-Remaining'].to_i
  end

  def value
    @remaining - @potential
  end
end

##
# Handler for Pushover API
class PushoverClient
  attr_reader :client

  def initialize(params)
    create_template params
    create_client
  end

  def send(params)
    data = @template.dup
    data.merge! params
    req = Net::HTTP::Post.new URL.path
    req.set_form_data data
    @client.request req
  end

  def close
    @client.finish
  end

  private

  def create_template(params)
    @template = {
      token: params[:appkey],
      user: params[:userkey]
    }
    @template[:device] = params[:device] if params[:device]
  end

  def create_client
    @client = Net::HTTP.new URL.host, URL.port
    @client.use_ssl = true
    @client.verify_mode = OpenSSL::SSL::VERIFY_PEER
    @client.start
  end
end

##
# Message object
class PushoverMessage
  attr_reader :buffer, :nick, :text, :is_pm

  def initialize(buffer, nick, text)
    @buffer, @is_pm = PushoverMessage.parse_buffer buffer
    @nick = nick
    @text = text
  end

  def clean_text
    clean = ''
    clean << "<#{@nick}> " unless @is_pm
    clean << @text
    clean.slice 0, (500 - @buffer.length)
  end

  class << self
    def parse_buffer(buffer)
      name = Weechat.buffer_get_string(buffer, 'full_name').split('.').last
      type = Weechat.buffer_get_string(buffer, 'localvar_type')
      [name, (type == 'private')]
    end
  end
end

##
# Handles message queue and configuration
class PushoverConfig
  def initialize
    @queue = []
    @health_check = 200
    @rate_calc = 0
    load_options
    load_hooks
  end

  def command_hook(_, _, args)
    case args
    when 'enable' then enable!
    when 'disable' then disable!
    when /^set (?<option>\w+) (?<value>[\w]+)/
      set Regexp.last_match['option'], Regexp.last_match['value']
    else
      Weechat.print('', "Syntax: #{completion_text}")
    end
    Weechat::WEECHAT_RC_OK
  end

  def message_hook(*args)
    buffer, nick, text = args.values_at(1, 6, 7)
    if Weechat.config_string_to_boolean(@options[:enabled]).to_i.zero?
      return Weechat::WEECHAT_RC_OK
    end
    unless Weechat.config_string_to_boolean(@options[:onlywhenaway]).to_i.zero?
      away_msg = Weechat.buffer_get_string buffer, 'localvar_away'
      return Weechat::WEECHAT_RC_OK if away_msg && away_msg.length > 0
    end
    @queue << PushoverMessage.new(buffer, nick, text)
    Weechat::WEECHAT_RC_OK
  end

  def timer_hook(*_)
    return Weechat::WEECHAT_RC_OK if @queue.empty?
    if @health_check < 0
      @health_check += 1
      return Weechat::WEECHAT_RC_OK
    end
    coalesce_messages if @rate_calc < 0
    send_messages
    Weechat::WEECHAT_RC_OK
  end

  private

  def coalesce_messages
    # Dummy method for now
  end

  def send_messages
    client = PushoverClient.new @options
    @queue = @queue.drop_while do |message|
      resp = client.send(
        title: message.buffer,
        message: message.clean_text,
        priority: @options[message.is_pm ? :pm_priority : :hilight_priority]
      )
      parse_response resp
    end
  end

  def parse_response(resp)
    case resp.code
    when /200/
      @rate_calc = RateCalc.new(resp, @options[:interval]).value
    when /429/
      disable! 'Pushover message limit exceeded'
    when /4\d\d/
      disable! "Pushover error: #{resp.body}"
    else
      server_failure!
    end
  end

  def disable!(reason)
    Weechat.print '', reason
    Weechat.print '', 'Disabling Pushover notifications'
    @options[:enabled] = '0'
    @queue.clear
    false
  end

  def server_failure!
    Weechat.print '', 'Pushover server error detected, delaying notifications'
    @health_check -= 5
    false
  end

  def set(option, value)
    if @options.keys.include? option.to_sym
      @options[option.to_sym] = value
      Weechat.config_set_plugin option, value
      Weechat.print '', "Pushover: set #{option} to #{value}"
      load_hooks if [:interval].include? option.to_sym
    else
      Weechat.print '', "Available options: #{@options.keys.join ', '}"
    end
  end

  def load_options
    @options = DEFAULTS.dup
    @options.each_key do |key|
      value = Weechat.config_get_plugin key.to_s
      @options[key] = value if value
      Weechat.config_set_plugin key.to_s, @options[key]
    end
  end

  def load_hooks
    @hooks.each_value { |x| Weechat.unhook x } if @hooks
    @hooks = {
      command: Weechat.hook_command(
        'pushover', 'Control Pushover options',
        'set OPTION VALUE', '', "#{completion_text}",
        'command_hook', ''
      ),
      message: Weechat.hook_print('', 'irc_privmsg', '', 1, 'message_hook', ''),
      timer: Weechat.hook_timer(@options[:interval].to_i * 1000, 0, 0, 'timer_hook', '')
    }
  end

  def completion_text
    "set #{@options.keys.join '|'}"
  end
end

def weechat_init
  Weechat.register(
    'pushover', 'Les Aker <me@lesaker.org>',
    '0.0.1', 'MIT',
    'Send hilight notifications via Pushover',
    '', ''
  )
  $Pushover = PushoverConfig.new
  Weechat::WEECHAT_RC_OK
end

require 'forwardable'
extend Forwardable
def_delegators :$Pushover, :message_hook, :command_hook, :timer_hook