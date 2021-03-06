#!/usr/bin/env ruby

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
#
# Sample framework based on katello-cvmanager (https://github.com/RedHatSatellite/katello-cvmanager/)

require 'optparse'
require 'yaml'
require 'apipie-bindings'
require 'highline/import'
require 'time'
require 'logging'
require 'awesome_print'

@defaults = {
  :noop        => false,
  :keep        => 5,
  :uri         => 'https://localhost',
  :timeout     => 300,
  :user        => 'admin',
  :pass        => nil,
  :org         => 1,
  :lifecycle   => 1,
  :force       => false,
  :wait        => false,
  :sequential  => 0,
  :promote_cvs => false,
  :checkrepos  => false,
  :verbose     => false,
  :description => 'autopublish',
  :verify_ssl  => true,
}

@options = {
  :yamlfile  => 'options.yaml',
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{opts.program_name} ACTION [options]"
  opts.version = "0.1"
  
  opts.separator ""
  opts.separator "#{opts.summary_indent}ACTION can be any of [clean,update,publish,promote]"
  opts.separator ""

  opts.on("-U", "--uri=URI", "URI to the Satellite") do |u|
    @options[:uri] = u
  end
  opts.on("-t", "--timeout=TIMEOUT", OptionParser::DecimalInteger, "Timeout value in seconds for any API calls. -1 means never timeout") do |t|
    @options[:timeout] = t
  end
  opts.on("-u", "--user=USER", "User to log in to Satellite") do |u|
    @options[:user] = u
  end
  opts.on("-p", "--pass=PASS", "Password to log in to Satellite") do |p|
    @options[:pass] = p
  end
  opts.on("-o", "--organization-id=ID", "ID of the Organization to manage CVs in") do |o|
    @options[:org] = o
  end
  opts.on("-k", "--keep=NUM", OptionParser::DecimalInteger, "how many unused versions should be kept") do |k|
    @options[:keep] = k
  end
  opts.on("-c", "--config=FILE", "configuration in YAML format") do |c|
    @options[:yamlfile] = c
  end
  opts.on("-l", "--to-lifecycle-environment=ID", OptionParser::DecimalInteger, "which LE should the promote be done to") do |l|
    @options[:lifecycle] = l
  end
  opts.on("-d", "--description=STRING", "Description to use for publish operations") do |d|
    @options[:description] = d
  end
  opts.on("-n", "--noop", "do not actually execute anything") do
    @options[:noop] = true
  end
  opts.on("-f", "--force", "force actions that otherwise would have been skipped") do
    @options[:force] = true
  end
  opts.on("--wait", "wait for started tasks to finish") do
    @options[:wait] = true
  end
  opts.on("--sequential [NUM]", OptionParser::DecimalInteger, "wait for each (or NUM) started task(s) to finish before starting the next one") do |s|
    @options[:wait] = true
    @options[:sequential] = s || 1
  end
  opts.on("--checkrepos", "check repository content was changed before publish") do
    @options[:checkrepos] = true
  end
  opts.on("--verbose", "Get verbose logs from cvmanager") do
    @options[:verbose] = true
  end
  opts.on("--no-verify-ssl", "don't verify SSL certs") do
    @options[:verify_ssl] = false
  end
end
optparse.parse!


# Load the configuration file 

@defaults.each do |key,val|
  if not @options.has_key?(key)
    @options[key] = val
  end
end

# Ask for Satellite username and password
if not @options[:user]
  @options[:user] = ask('Satellite username: ')
end

if not @options[:pass]
  @options[:pass] = ask('Satellite password: ') { |q| q.echo = false }
end


# Set up the connection
# Uses username and password
@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout]}, {:verify_ssl => @options[:verify_ssl]})

# To print debug logging of the connection to STDOUT
# use following 
#@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout]}, :logger => Logging.logger(STDOUT)}, {:verify_ssl => @options[:verify_ssl]})


def puts_verbose(message)
  if @options[:verbose]
    puts "    [VERBOSE] #{message}"
  end
end

# Sample method of waiting for a task to finish
def wait(tasks)
  need_wait = tasks
  if @options[:wait]
    last_need_wait = []
    silence = false
    wait_secs = 0
    while not need_wait.empty?
      if wait_secs < 60
        wait_secs += 10
      end
      puts "waiting #{wait_secs} for pending tasks: #{need_wait}" unless silence
      sleep wait_secs
      last_need_wait = need_wait
      need_wait = []
      tasks.each do |task_id|
        req = @api.resource(:foreman_tasks).call(:show, {:id => task_id})
        if req['pending']
          need_wait << task_id
        end
      end
      if (wait_secs >= 60 and (last_need_wait.sort == need_wait.sort))
          puts "Silencing output until there's a task status change..." unless silence
          silence = true
      else
          silence = false
      end
    end
  end
  return need_wait
end


subscriptions=[]
begin
  req = @api.resource(:subscriptions).call(:index, {:organization_id => @options[:org], :full_results => true})
  subscriptions = subscriptions.concat(req['results'])
end

subscriptions.each do |sub|
  puts "#{sub['id']}:  #{sub['name']}"
end

 
