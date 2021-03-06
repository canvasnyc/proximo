require 'rubygems'
require 'sinatra'
require 'net/http'
require 'yaml'
require 'uri'

# Listen on default HTTP port and select config by the request's hostname.
set :port, 80

# Do not automatically serve local files. We want all requests to go through 
# routes, so we can dynamically determine what to do per request.
set :static, false

# Read from settings file before handling each request (no restarts required).
before do
  host = request.host
  @host = host
  @settings = settings_for(host)
  fail "Settings not defined for hostname '#{host}'." if @settings.nil?

  docroot = @settings['docroot']
  fail "docroot not defined for hostname '#{host}'." if docroot.nil?
  fail "Docroot '#{docroot}' does not exist." if !File.exists?(docroot)
  set :public_folder, docroot

  # If the requested path ends in a slash, and an index.html is available in a
  # local directory with that name, explicitly append 'index.html' to the path. 
  # Otherwise, let the directory be fetched from remote server.
  path = request.path_info  
  path << 'index.html' if path.end_with?('/') && exists_locally?(path + 'index.html')
  @path = path

  # set remote_host based on proxy settings
  proxy = @settings['proxy']
  if proxy.is_a?(String)
    # Style #1
    #   proxy: foo.com
    @remote_host = proxy
  elsif proxy.is_a?(Hash)
    # Style #2
    #   proxy:
    #     default: foo.com
    #     others:
    #       - for: /images/*
    #         use: bar.com
    other = proxy['others'].find { |other| to_regexp(other['for']) =~ path }
    @remote_host = other.nil? ? proxy['default'] : other['use']
  end
end

# delegate all GET/POST requests to custom handlers
get '*' do 
  if serve_local?
    serve_local
  else
    serve_remote
  end
end

post '*' do
  if serve_local?
    serve_local
  else
    serve_remote
  end
end



#----------------------------------------------------------------------
# HTTP handlers (local and remote)
#----------------------------------------------------------------------

# rules for which resources are to be served from local filesystem
def serve_local?
  # serve local files if no remote host was defined
  return true if @remote_host.nil?
  
  # otherwise, serve local files if all of the following are true
  !matches_any?(@path, @settings['always_from_remote']) &&  # path does not match an 'always_from_remote' pattern
  exists_locally?(@path) &&                                 # path exists on local filesystem
  !@path.end_with?('/')                                     # path is not a directory (forces fetch of remote 
end                                                         #   directory indexes such as index.jsp)

def serve_local
  send_file(File.expand_path(settings.public_folder + unescape(@path)))
end

def serve_remote
  url = URI.parse("http://#{@remote_host}")
  http = Net::HTTP.new(url.host, url.port)
  path = @path + '?' + request.query_string
  
  # forward incoming GET/POST requests to remote host and capture response
  if request.get?
    remote = http.get(path, custom_headers)
  elsif request.post?
    remote = http.post(path, form_data, custom_headers)
  end

  # set HTTP response headers based on remote host's response
  status remote.code
  content_type remote['content-type']
  response['Set-Cookie'] = remote['Set-Cookie'] if !remote['Set-Cookie'].nil?
  
  # if present, rewrite redirect URL to use local hostname (instead of remote hostname)
  url = remote['Location']
  response['Location'] = url.gsub(@remote_host, @host) if !url.nil?

  # return body of remote host's response (to be served by get/post handlers)
  remote.body
end

def custom_headers
  headers = {}  
  headers['Cookie']       = @env['HTTP_COOKIE'] if !request.cookies.empty?
  headers['Content-Type'] = request.content_type if request.post?
  headers['User-Agent']   = request.user_agent
  headers['Referer']      = @env['HTTP_REFERER'] if @env.has_key?('HTTP_REFERER')
  headers
end

def form_data
  @env['rack.request.form_vars'] || ''
end



#----------------------------------------------------------------------
# utility functions
#----------------------------------------------------------------------

def settings_for(hostname)
  # look up settings for the requested hostname in YAML file
  yaml = File.join(File.dirname(__FILE__), 'proximo.yml')
  settings = YAML.load(File.open(yaml))
  return settings[hostname] unless settings[hostname].nil?
  
  # search aliases for the requested hostname
  settings.values.each do |opts|
    if opts.has_key? 'aliases'
      if opts['aliases'].any? { |host_alias| host_alias == hostname }
        return opts
      end
    end
  end
end

def exists_locally?(path)
  File.exists?(File.join(settings.public_folder, path))
end

def matches_any?(path, patterns)
  return false if patterns.nil?
  patterns.any? { |pattern| to_regexp(pattern) =~ path }
end

def to_regexp(string=nil)
  return if string.nil? 
  # convert string pattern to regular expression
  # - replace * wildcard with regex wildcard
  # - surround pattern with ^ and $ anchors
  # - make leading slash optional
  Regexp.compile('^\/?' + string.gsub('*', '(.*)') + '$')
end
