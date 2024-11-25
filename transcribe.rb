require 'net/http'
require 'uri'
require 'json'
require 'mime/types'

# Configuration
OPENAI_API_KEY = 'KEY'
WHISPER_API_URL = 'https://api.openai.com/v1/audio/transcriptions'
MODEL = 'whisper-1'  # Verify this with OpenAI's documentation later

# Maximum allowed file size in bytes (25 MB)
MAX_FILE_SIZE = 25 * 1024 * 1024  # 25 MB

# Check if file needs to be split
def needs_splitting?(file_size)
  file_size > MAX_FILE_SIZE
end

# Split audio into smaller chunks using FFmpeg
def split_audio(input_file, chunk_size_seconds, output_prefix)
  puts "Splitting audio into #{chunk_size_seconds}-second chunks..."
  # Generate command to split audio
  system("ffmpeg -i \"#{input_file}\" -f segment -segment_time #{chunk_size_seconds} -c copy #{output_prefix}%03d.mp3")
  unless $?.success?
    puts "Failed to split audio."
    exit 1
  end
end

# Helper method to format time in seconds to HH:MM:SS
def format_time(seconds)
  total_seconds = seconds.to_i
  hours = total_seconds / 3600
  minutes = (total_seconds % 3600) / 60
  secs = total_seconds % 60
  sprintf("%02d:%02d:%02d", hours, minutes, secs)
end

# Transcribe audio using Whisper API with timestamps and offset
def transcribe_audio(audio_file, output_text_file, time_offset)
  uri = URI.parse(WHISPER_API_URL)
  request = Net::HTTP::Post.new(uri)
  request['Authorization'] = "Bearer #{OPENAI_API_KEY}"

  # Prepare multipart form data
  boundary = "----RubyMultipartPost#{rand(1000000)}"
  request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"

  # Read the audio file
  audio_data = File.read(audio_file)
  mime_type = MIME::Types.type_for(audio_file).first.to_s

  # Construct the multipart body with 'model' and 'response_format' parameters
  body = []
  body << "--#{boundary}\r\n"
  body << "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
  body << "#{MODEL}\r\n"
  body << "--#{boundary}\r\n"
  body << "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"
  body << "verbose_json\r\n"
  body << "--#{boundary}\r\n"
  body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{File.basename(audio_file)}\"\r\n"
  body << "Content-Type: #{mime_type}\r\n\r\n"
  body << audio_data
  body << "\r\n--#{boundary}--\r\n"
  request.body = body.join

  # Send the request
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end

  # Handle the response
  if response.code.to_i == 200
    result = JSON.parse(response.body)
    segments = result['segments']

    if segments.nil? || segments.empty?
      puts "No transcription segments found in the response."
      puts "Full Transcription:"
      puts result['text'] if result['text']
      return
    end

    puts "Transcription for #{audio_file}:"

    # Append transcription with adjusted timestamps to the output file
    File.open(output_text_file, 'a') do |file|
      segments.each do |segment|
        adjusted_start = segment['start'] + time_offset
        adjusted_end = segment['end'] + time_offset
        start_time = format_time(adjusted_start)
        end_time = format_time(adjusted_end)
        text = segment['text'].strip

        # Print to console
        puts "[#{start_time} - #{end_time}] #{text}"

        # Write to file
        file.puts "[#{start_time} - #{end_time}] #{text}"
      end
      file.puts "\n"
    end

    puts "Transcription with timestamps appended to #{output_text_file}"
  else
    puts "Failed to transcribe audio #{audio_file}. HTTP Status Code: #{response.code}"
    puts "Response Body: #{response.body}"
  end
end

# Main execution flow
def main
  if ARGV.length < 1
    puts "Usage: ruby transcribe.rb path_to_audio_file [output_text_file]"
    exit 1
  end

  input_file = ARGV[0]
  output_text_file = ARGV[1] || "transcription_with_timestamps.txt"

  unless File.exist?(input_file)
    puts "File not found: #{input_file}"
    exit 1
  end

  file_size = File.size(input_file)
  puts "Input file size: #{file_size} bytes"

  if needs_splitting?(file_size)
    puts "File size exceeds the maximum limit of #{MAX_FILE_SIZE} bytes."
    # Define chunk size (e.g., 10 minutes per chunk)
    chunk_size_seconds = 600  # 10 minutes

    # Split the audio into chunks
    split_audio(input_file, chunk_size_seconds, "chunk_")

    # Get list of chunked files
    chunk_files = Dir.glob("chunk_*.mp3").sort

    if chunk_files.empty?
      puts "No chunks were created. Please check the input file and splitting parameters."
      exit 1
    end

    # Initialize cumulative time offset
    cumulative_offset = 0

    # Transcribe each chunk
    chunk_files.each do |chunk|
      transcribe_audio(chunk, output_text_file, cumulative_offset)
      # Update cumulative_offset by chunk duration
      # Estimate chunk duration (chunk_size_seconds)
      cumulative_offset += 600  # 10 minutes
    end

    # Optionally, clean up chunk files
    chunk_files.each do |chunk|
      File.delete(chunk) if File.exist?(chunk)
      puts "Deleted chunk file: #{chunk}"
    end
  else
    # Transcribe the single audio file with no offset
    transcribe_audio(input_file, output_text_file, 0)
  end

  puts "All transcriptions saved to #{output_text_file}"
end

# Run the script
main
