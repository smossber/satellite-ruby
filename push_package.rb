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

require 'optparse'
require 'yaml'
require 'apipie-bindings'
require 'highline/import'
require 'time'
require 'logging'
require 'awesome_print'
require 'pry'

@defaults = {
  :noop        => false,
  :keep        => 5,
  :uri         => 'https://localhost',
  :timeout     => 300,
  :user        => 'admin',
  :pass        => nil,
  :org         => 1,
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
  :yamlfile  => 'cvmanager.yaml',
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
  opts.on("-l", "--lifecycle-environments=Test,Prod", "which LE should the Incremental CV update be targeted for") do |l|
    @options[:lifecycle_environments] = l
  end
  opts.on("-w", "--content-view=ID", "which Content View targeted for promition") do |w|
    @options[:content_view] = w
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

if ARGV.empty?
  puts optparse.help
  exit
end

#@yaml = YAML.load_file(@options[:yamlfile])
#
#if @yaml.has_key?(:settings) and @yaml[:settings].is_a?(Hash)
#  @yaml[:settings].each do |key,val|
#    if not @options.has_key?(key)
#      @options[key] = val
#    end
#  end
#end

@defaults.each do |key,val|
  if not @options.has_key?(key)
    @options[key] = val
  end
end

if not @options[:user]
  @options[:user] = ask('Satellite username: ')
end

if not @options[:pass]
  @options[:pass] = ask('Satellite password: ') { |q| q.echo = false }
end

# sanitize non-complete config files
#[:cv, :ccv].each do |key|
#  if not @yaml.has_key?(key)
#    @yaml[key] = {}
#  end
#end
#[:publish, :promote].each do |key|
#  if not @yaml.has_key?(key)
#    @yaml[key] = []
#  end
#end
#

@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout]}, {:verify_ssl => @options[:verify_ssl]})
#@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout], :logger => Logging.logger(STDOUT)}, {:verify_ssl => @options[:verify_ssl]})

def puts_verbose(message)
  if @options[:verbose]
    puts "    [VERBOSE] #{message}"
  end
end
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

def get_lifecycle_environment(le_name)
  lifecycle_environment = []
  # https://satellite/apidoc/v2/lifecycle_environments.html
  if le_name != "Library"
	  req = @api.resource(:lifecycle_environments).call(:index, {:organization_id => @options[:org], :full_results => true, :library => false, :name => le_name})
  else
	  req = @api.resource(:lifecycle_environments).call(:index, {:organization_id => @options[:org], :full_results => true, :library => true, :name => le_name})
  end

  if req['total'] == 0
	  fail "Couldn't find any Lifecycle Environments"
  end
  if !req['results'].empty?
	  #lifecycle_environment = le.concat(req['results']).first
	  lifecycle_environment = req['results'].first
	  return lifecycle_environment
  else
	  fail "Couldn't find Lifecycle Environments, but the results wasn't 0"
  end
end

def get_previous_lifecycle_environment(le_name)
	if lifecycle_environment = get_lifecycle_environment(le_name)
		if not lifecycle_environment['prior']['name'].empty?
			puts_verbose("Prior LE for #{lifecycle_environment['name']} is #{lifecycle_environment['prior']['name']}")
			return get_lifecycle_environment(lifecycle_environment['prior']['name'])
		end
	else
		fail "Didn't get Lifecycle Environment"
	end
end

def get_repo_id(repo_name)
  repo_id = get_resource_id(:repositories, repo_name)
end

def get_cv_id(cv_name)
  cv_id = get_resource_id(:content_views, cv_name)
end

def get_le_id(le_name)
  le_id = get_resource_id(:lifecycle_environments, le_name)
end

def get_resource_id(resource_type, resource_name)
	req = @api.resource(resource_type).call(:index, {:organization_id => @options[:org], :full_results => true, :library => false, :name => resource_name})
  if req['total'] == 1
    res = req['results'].first
  elsif req['total'] > 1
    fail "Too many #{resource_type}'s found, specify further"
  else
    fail "Couldn't find any objects of resource type #{resource_type} with name: #{resource_name}"
  end
  res_id = res['id']
end

def get_resource(resource_type, resource_id)
	req = @api.resource(resource_type).call(:show, {:organization_id => @options[:org], :id => resource_id})
end

# Call the incremental update 
def incremental_update(le_id, ccv_id, package_ids)
  tasks=[]

  description = "Incremental Update \n Fast Track for packages: #{package_ids}"
  req = @api.resource(:content_view_versions).call(:incremental_update,
                                                   {
                                                   :content_view_version_environments => [{ 
                                                            :content_view_version_id => ccv_id,
                                                            :environment_ids => [ le_id ]
                                                   }],
                                                   :add_content => {
                                                        :package_ids => package_ids
                                                   },
                                                   :description => description
                                                   })
  tasks << req['id']
  wait(tasks)
  
end

def identify_cvv_in_le(cv, le_id)
  puts_verbose("Finding #{cv['name']} versions belonging to Lifecycle Environment ID #{le_id}")

  cvv_id = "" 
  cv['versions'].sort_by { |v| v['version'].to_f }.reverse.each do |version|
    if not version['environment_ids'].empty?
      if version['environment_ids'].include?(le_id)
        puts_verbose "    FOUND: #{cv['name']} v#{version['version']} (id: #{version['id']}) in LE: #{le_id}"
        return version['id']
      end
    end
  end
end


action = ARGV.shift

repo_id = get_repo_id("repo-puppet-deps-rpms")
puts_verbose("Repo ID: #{repo_id}")

package_ids = [17210]

# Fetch CV information
cv_id = get_cv_id("cv-puppet-deps")
puts_verbose("CV ID: #{cv_id}")
cv = get_resource(:content_views, cv_id)

# Pick out the different LE's from input
lifecycle_environments = []
if @options[:lifecycle_environments].include?(',')
  @options[:lifecycle_environments].split(',').each do |le|
    lifecycle_environments << le
  end
end

# Check that the LE's exists and save ID's
le_ids=[]
lifecycle_environments.each do |le_name|
    le_ids << get_le_id(le_name)
end

# Add CV'versions to hash
#le_cvvs=[]
#for le in le_ids do 
#  le_cvvs << { le => ['1','2'] }
#end

le_cvv=[]
# Get CV version for every lifecycle, and save that to hash
# It's the cv verison we need to target for incremental update later
for le_id in le_ids do
  if cv['composite']
    puts "CV is composit"
    cv['component_ids'].each do |cv_id|
      cv = get_resource(:content_view, cv_id)
      if cv['repositories'].include?(repo_id)
        cvv_id = identify_cvv_in_le(cv, le_id)
        le_cvv << { le_id => cvv_id }
      end
    end
  else
    cvv_id = identify_cvv_in_le(cv, le_id)
    le_cvv << { le_id => cvv_id }
  end
end
puts le_cvv
puts "schedule incremental update with:"
le_cvv.each do |row|
  row.each do |le, cvv|
    puts "incremental_update(le #{le}, cvv #{cvv}, package_ids)"
    incremental_update(le, cvv, package_ids)
    sleep(10)
  end
end
