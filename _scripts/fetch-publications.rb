#!/usr/bin/env ruby
# Fetches publications from PubMed for author "Toptan T" and attempts to
# download OpenGraph thumbnail images via DOI. Outputs _data/publications.yaml.

require "net/http"
require "json"
require "yaml"
require "uri"
require "fileutils"

AUTHOR = "Toptan T"
BASE_DIR = File.expand_path("..", __dir__)
DATA_FILE = File.join(BASE_DIR, "_data", "publications.yaml")
IMAGE_DIR = File.join(BASE_DIR, "images", "publications")

FileUtils.mkdir_p(IMAGE_DIR)

def fetch_json(url)
  uri = URI(url)
  response = Net::HTTP.get_response(uri)
  JSON.parse(response.body)
end

def fetch_html(url, limit = 5)
  return nil if limit <= 0
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = 10
  http.read_timeout = 10
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "Mozilla/5.0 (compatible; LabWebsite/1.0)"
  response = http.request(request)
  case response
  when Net::HTTPRedirection
    fetch_html(response["location"], limit - 1)
  when Net::HTTPSuccess
    response.body
  else
    nil
  end
rescue StandardError => e
  $stderr.puts "  Warning: could not fetch #{url}: #{e.message}"
  nil
end

def extract_og_image(html)
  return nil unless html
  match = html.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i)
  match ||= html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i)
  match ? match[1] : nil
end

def download_image(url, filepath)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = 10
  http.read_timeout = 15
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "Mozilla/5.0 (compatible; LabWebsite/1.0)"
  response = http.request(request)
  if response.is_a?(Net::HTTPRedirection)
    return download_image(response["location"], filepath)
  end
  return false unless response.is_a?(Net::HTTPSuccess)

  content_type = response["content-type"] || ""
  return false unless content_type.include?("image")

  File.open(filepath, "wb") { |f| f.write(response.body) }
  true
rescue StandardError => e
  $stderr.puts "  Warning: could not download image #{url}: #{e.message}"
  false
end

def sanitize_filename(doi)
  doi.gsub(%r{[/:\\]}, "-").gsub(/[^a-zA-Z0-9._-]/, "")
end

# Step 1: Search PubMed for article IDs
puts "Searching PubMed for '#{AUTHOR}'..."
search_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?" \
             "db=pubmed&term=#{URI.encode_www_form_component(AUTHOR + '[Author]')}" \
             "&retmax=100&retmode=json"
search_result = fetch_json(search_url)
ids = search_result.dig("esearchresult", "idlist") || []
puts "Found #{ids.length} articles."

if ids.empty?
  puts "No articles found. Exiting."
  exit 0
end

# Step 2: Fetch summaries for all IDs
puts "Fetching article summaries..."
summary_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?" \
              "db=pubmed&id=#{ids.join(',')}&retmode=json"
summary_result = fetch_json(summary_url)
articles = summary_result.dig("result") || {}

publications = []

ids.each do |pmid|
  article = articles[pmid]
  next unless article.is_a?(Hash)

  title = article["title"] || "Untitled"
  # Clean up title - remove trailing period if present
  title = title.sub(/\.\s*$/, "")

  authors = (article["authors"] || []).map { |a| a["name"] }
  journal = article["fulljournalname"] || article["source"] || ""
  pub_date = article["pubdate"] || ""
  elocation_id = article["elocationid"] || ""
  doi = nil

  # Extract DOI from articleids
  (article["articleids"] || []).each do |aid|
    if aid["idtype"] == "doi"
      doi = aid["value"]
      break
    end
  end

  # Try elocationid if no DOI found
  if doi.nil? && elocation_id =~ /doi:\s*(.+)/i
    doi = $1.strip
  end

  # Parse date
  date_str = pub_date
  begin
    if pub_date =~ /^(\d{4})\s+(\w+)\s+(\d+)/
      date_str = "#{$1}-#{$2}-#{$3}"
    elsif pub_date =~ /^(\d{4})\s+(\w+)/
      date_str = "#{$1}-#{$2}-01"
    elsif pub_date =~ /^(\d{4})/
      date_str = "#{$1}-01-01"
    end
  rescue
    date_str = pub_date
  end

  # Build publication entry
  pub = {
    "id" => "pmid-#{pmid}",
    "title" => title,
    "authors" => authors,
    "publisher" => journal,
    "date" => date_str,
    "type" => "paper",
    "link" => doi ? "https://doi.org/#{doi}" : "https://pubmed.ncbi.nlm.nih.gov/#{pmid}/",
  }

  # Step 3: Try to fetch OG image via DOI
  if doi
    image_filename = sanitize_filename(doi)
    existing = Dir.glob(File.join(IMAGE_DIR, "#{image_filename}.*"))

    if existing.any?
      pub["image"] = "images/publications/#{File.basename(existing.first)}"
      puts "  [cached] #{title[0..60]}..."
    else
      puts "  [fetch]  #{title[0..60]}..."
      doi_url = "https://doi.org/#{doi}"
      html = fetch_html(doi_url)
      og_image = extract_og_image(html)

      if og_image
        ext = case og_image
              when /\.png/i then ".png"
              when /\.gif/i then ".gif"
              when /\.webp/i then ".webp"
              else ".jpg"
              end
        img_path = File.join(IMAGE_DIR, "#{image_filename}#{ext}")
        if download_image(og_image, img_path)
          pub["image"] = "images/publications/#{image_filename}#{ext}"
          puts "    -> saved image"
        else
          puts "    -> image download failed"
        end
      else
        puts "    -> no og:image found"
      end
      sleep 0.5 # rate limiting
    end
  else
    puts "  [no DOI] #{title[0..60]}..."
  end

  publications << pub
end

# Sort by date descending
publications.sort_by! { |p| p["date"] || "" }.reverse!

# Write YAML
File.open(DATA_FILE, "w") do |f|
  f.write("# Auto-generated from PubMed. Do not edit manually.\n")
  f.write("# Run: ruby _scripts/fetch-publications.rb\n\n")
  f.write(publications.to_yaml)
end

puts "\nDone! Wrote #{publications.length} publications to #{DATA_FILE}"
