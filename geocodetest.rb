#!/usr/bin/env ruby

require 'rubygems'

require 'cgi'
require 'uri'
require 'net/http'
require 'JSON'

$verbose = false

# Geocode the same address across multiple services
def multi_geocode_address(address)
  geocoders = {
    'google' => :address_to_coordinates_google,
    'dstk' => :address_to_coordinates_dstk,
    'nominatim' => :address_to_coordinates_nominatim,
  }
  result = {}
  geocoders.each do |name, method|
    result[name] = send(method, address)
  end
  result
end

def address_to_coordinates_google(address)
  address_to_coordinates_google_like(address, 'http://maps.googleapis.com')
end

def address_to_coordinates_dstk(address)
  address_to_coordinates_google_like(address, 'http://www.datasciencetoolkit.org')
end

def address_to_coordinates_nominatim(address)
  base_url = 'http://nominatim.openstreetmap.org/search/?format=json&q='
  full_url = base_url + CGI::escape(address)
  response = get_http_json(full_url)
  if !response
    if $verbose then $stderr.puts "Geocoding returned a bad response for URL '#{full_url}'" end
    return nil
  end
  info = response[0]
  if !info
    if $verbose then $stderr.puts "Geocoding returned no results for URL '#{full_url}'" end
    return nil
  end
  if !info['lat'] or !info['lon']
    if $verbose then $stderr.puts "Geocoding returned no coordinates in #{info.to_json} for URL '#{full_url}'" end
    return nil
  end
  lat = info['lat'].to_f
  lng = info['lon'].to_f
  {'lat' => lat, 'lng' => lng}
end

def address_to_coordinates_google_like(address, base_url)
  method_path = '/maps/api/geocode/json?sensor=false&address='
  full_url = base_url + method_path + CGI::escape(address)
  response = get_http_json(full_url)
  if !response
    if $verbose then $stderr.puts "Geocoding returned a bad response for URL '#{full_url}'" end
  end
  status = response['status']
  if status != 'OK'
    if $verbose then $stderr.puts "Geocoding returned a bad status '#{status}' for URL '#{full_url}'" end
    return nil
  end
  # Assume the first result is the best one, since there's no confidence value
  # to sort them by
  info = response['results'][0]
  result = info['geometry']['location']
  result
end

def get_http(url)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  headers = { 'User-Agent' => 'geocodetest - contact pete@jetpac.com in case of problems' }
  request = Net::HTTP::Get.new(uri.request_uri, headers)
  response = http.request(request)
  result = nil
  if response.code != '200'
    if $verbose then $stderr.puts "Bad response code #{response.status} for '#{url}'" end
    result = nil
  else
    result = response.body
  end
  result
end

def get_http_json(url)
  body = get_http(url)
  if !body
    return nil
  end
  result = JSON.parse(body)
  if !result
    if $verbose then $stderr.puts "Couldn't parse as JSON: '#{body}'" end
    return nil
  end
  result
end

# Adapted from http://www.zipcodeworld.com/samples/distance.js.html
# Returns the approximate distance in meters between two sets of coordinates
def distance_from_lat_lon(a, b)
  lat1 = a['lat']
  lon1 = a['lng']
  lat2 = b['lat']
  lon2 = b['lng']
  radlat1 = Math::PI * lat1/180
  radlat2 = Math::PI * lat2/180
  radlon1 = Math::PI * lon1/180
  radlon2 = Math::PI * lon2/180
  theta = lon1-lon2
  radtheta = Math::PI * theta/180
  dist = Math.sin(radlat1) * Math.sin(radlat2) + Math.cos(radlat1) * Math.cos(radlat2) * Math.cos(radtheta);
  dist = [[dist, -1.0].max, 1.0].min
  dist = Math.acos(dist)
  dist = dist * 180/Math::PI
  # seconds-in-a-degree * statute-miles-in-a-nautical-mile * kilometers-in-a-mile * meters-in-a-kilometer!
  # See http://stackoverflow.com/questions/389211/geospatial-coordinates-and-distance-in-kilometers-updated-again
  dist = dist * 60 * 1.1515 * 1.609344 * 1000
  dist
end

# Runs through the geocoders, and returns whether their results are close enough
def test_geocoders(address, threshold)
  locations = multi_geocode_address(address)
  # Assume that Google gets it right!
  authoritative_location = locations['google']
  if !authoritative_location
    if $verbose then $stderr.puts "Google couldn't geocode '#{address}'" end
  end
  result = {}
  locations.each do |name, location|
    if !authoritative_location or !location
      distance = nil
      passed = false
    else
      distance = distance_from_lat_lon(location, authoritative_location)
      passed = (distance < threshold)
    end
    result[name] = { 'passed' => passed, 'distance' => distance, 'location' => location }
  end
  result
end

# Run as a command line tool if this file hasn't been 'require'd as a library
if __FILE__ == $0

  require 'trollop'

  opts = Trollop::options do
    version 'geocodetest.rb 0.0.1 (c) 2013 Pete Warden'
    banner 'Measures the quality of address to coordinate results across multiple services'
    opt :input, 'input file (one address per line)', :type => String
    opt :distance, 'test distance in meters (default is 100)', :type => Integer, :default => 100
    opt :verbose, 'output debugging information to stderr'
    opt :showdistances, 'output distances rather than pass/fail information'
    opt :showlocations, 'output locations rather than pass/fail information', :short => 'l'
  end

  if !opts[:input] then Trollop::die "Missing required input file" end

  $verbose = opts[:verbose]

  # Run through the input file, and output a row of CSV data for each result
  is_first = true
  names = nil
  IO.foreach(opts[:input]) do |address|
    test_results = test_geocoders(address, opts[:distance])
    # Create the CSV header if this is the first address
    if is_first
      index = 0
      names = test_results.keys.sort
      headers = names.dup
      headers << 'address'
      puts headers.join(",")
      is_first = false
    end
    output = []
    names.each do |name|
      result = test_results[name]
      passed = result['passed']
      if opts[:showdistances]
        distance = result['distance']
        if !distance
          output << 'NA'
        else
          output << distance.to_s
        end
      elsif opts[:showlocations]
        location = result['location']
        if !location
          output << 'NA'
        else
          output << '"' + location['lat'].to_s + ',' + location['lng'].to_s + '"'
        end
      else
        if passed
          output << 'Y'
        else
          output << 'N'
        end
      end
    end
    output << address
    puts output.join(',')
  end

end
