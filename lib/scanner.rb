require_relative '../lib/support'
require 'rest-client'
require 'socket'
require 'cupsffi'

SIMULATE = false

class Scanner

  include Support

  def initialize(web_server_uri, options)
    @web_server_uri = web_server_uri
    @doc_name_index = '000'
    @scanned_documents = Array.new

    if SIMULATE
      @doc_name_prefix = File.join(Dir.tmpdir, "cdc_2020-05-18-215626_")
    else
      @doc_name_prefix = File.join(Dir.tmpdir, "cdc_#{Time.now.strftime("%Y-%m-%d-%H%M%S")}_")
    end

    @scann_converter_running = false
    @unpaper_speed = options[:unpaper_speed] == 'y'
  end


  ############## DRB Commands - Called from remote to list scann devices *********************************

  def scanner_list_devices
    puts "**List Devices**"
    device_list = Hash.new

    if SIMULATE
      device_list['Simulation'] = 'yes'
    else
      # ["Canon LiDE 35/40/50", "genesys:libusb:001:004", "FUJITSU ScanSnap S300", "epjitsu:libusb:002:005"]
      device_string = %x[scanimage -f"%v %m|%d|"].split('|')
      0.step(device_string.count - 1, 2) { |i| device_list[device_string[i]] = device_string[i + 1]; puts "Device: #{device_string[i]}" }
    end

    device_list

  end


  #### scans a page (frontpage) and prints it on default printer of server

  def scanner_copy(device)
    puts "********** Scanner Copy *************"
    @result = '-'
    @doc_name_index = @doc_name_index.next
    scan_tmp_file = @doc_name_prefix + "_#{@doc_name_index}_%03d.copy.ppm"
    mode = 'Gray'
    resolution = '300'
    source = "'ADF Duplex'"
    scan_command = ""

    ["scanimage",
     "--device=" + device,
     "--mode=" + mode,
     "--contrast=" + "70",
     "--brightness=" + "40",
     "--format=" + "ppm",
     "--resolution=" + resolution,
     "--format=" + "ppm",
     "--batch=" + scan_tmp_file,
     "--source=" + source,
     "2>&1"].each { |c| scan_command = scan_command + c + " " }

    puts "Scan Command: #{scan_command}"

    printer_name = CupsPrinter.default_printer
    puts "Default Printer: #{printer_name}"

    #### just for testing
    if printer_name.nil?
      scanner_status_update("Copy-Error: No default printer found", true)
      return
    end

    @printer = CupsPrinter.new(printer_name)
    if @printer.nil?
      scanner_status_update("Copy-Error: No printer found", true)
      return
    end

    puts @printer.attributes

    t = Thread.new do

      begin

        scanner_status_update("Start Copy: #{device}")

        ### File PrintThread
        @prepare_print_thread = prepare_print_thread unless @scann_printer_running

        result = %x[#{scan_command}] ############ HERE IS THE SCANNING
        if result.include? "feeder out of document"
          scanner_status_update("Copy-Feeder: Empty", true) ## true to say we are running to scan new data
        else
          scanner_status_update("Copy-Warning: #{result}", true) ## true to say we are running to scan new data
        end

      rescue => e
        puts "************ ERROR *****: #{e.message}"
        scanner_status_update("Copy-Error: #{e.message}", true)
        raise
      end

    end

    t.abort_on_exception = true


  end

  ### Send scanned files to the printer  *************************************************************

  def prepare_print_thread

    @scann_printer_terminate = false
    @scann_printer_running = true
    sleep_count = 0


    t = Thread.new do

      job_list = []

      check_program('empty-page'); check_program('unpaper');

      until @scann_printer_terminate do
        sleep 1; sleep_count = sleep_count + 1
        if sleep_count > 150 then
          @scann_printer_terminate = true
        end

        scanned_files = Dir.glob(@doc_name_prefix + "*.copy.ppm").sort_by { |f| File.basename(f) }

        scanned_files.each do |f_scanned_ppm|
          sleep_count = 0

          if not system "empty-page -p 0.6 -i '#{f_scanned_ppm}'" then
            f = f_scanned_ppm.split('.')[0] #name without extension

            if @scanned_documents.index(f).nil?
              scanner_status_update("Process: Cleaning")

              puts "Start unpaper with speed-option: #{@unpaper_speed.to_s}"

              if @unpaper_speed then
                ### quick version for unpaper, not using --no-mask-scan
                res1 = %x[unpaper -v --overwrite  --mask-scan-size 120 --sheet-size a4 --no-grayfilter --no-mask-scan --no-blackfilter  --pre-border 0,200,0,0 '#{f_scanned_ppm}' '#{f}.unpaper_copy.ppm']
              else
                res1 = %x[unpaper -v --overwrite  --mask-scan-size 120 --post-size a4 --sheet-size a4 --no-grayfilter --no-blackfilter  --pre-border 0,200,0,0 '#{f_scanned_ppm}' '#{f}.unpaper_copy.ppm']
              end

              puts res1
#                raise "Error unpaper - #{res1}" unless File.exist?("#{f}.unpaper.ppm")
#                raise "Error unpaper - #{res1}" unless res1[0..10] == "unpaper 6.1"

              res3 = %x[convert -page A4 '#{f}.unpaper_copy.ppm' '#{f}.unpaper_copy.pdf']
              puts res3
              raise "Error unpaper or convert - #{res3}" unless File.exist?("#{f}.unpaper_copy.pdf")

              puts "Start print"
              job = @printer.print_file("#{f}.unpaper_copy.pdf")
              sleep 2
              puts "Job Status:#{job.status}"
              job_list.push(job)

#              FileUtils.rm "#{f}.unpaper_copy.ppm"
#              FileUtils.rm "#{f}.unpaper_copy.pdf"

            end
          end
          res6 = FileUtils.rm f_scanned_ppm unless SIMULATE
        end

        puts "--check for new work, print jobs:"

        job_list.each { |job|
          puts job.status
        }

      end

      @scann_converter_running = false
      puts '-- terminate convert thread -no new work'
      sleep 0.5
    end
    t.abort_on_exception = true
    t
  end

  ### called via DRB to start scann process *************************************************************

  def scanner_start_scann(device, color)
    puts "********** Scanner to DocBox  *************"
    ## new thread needed to return to DRB call asap

    t = Thread.new do

      begin

        scanner_status_update("Start: #{device}, color: #{color}")
        scann_command = scanner_build_command(device, color)

        ### File Conversion Thread
        @prepare_upload_thread = prepare_upload_thread unless @scann_converter_running

        if SIMULATE
          sleep(5)
          scanner_status_update("SIMULATING", true) ## true to say we are running to scan new data
        else

          result = %x[#{scann_command}] ############ HERE IS THE SCANNING
          if result.include? "feeder out of document"
            scanner_status_update("Feeder: Empty", true) ## true to say we are running to scan new data
          else
            scanner_status_update("Warning: #{result}", true) ## true to say we are running to scan new data
          end
        end
      rescue => e
        puts "************ ERROR *****: #{e.message}"
        scanner_status_update("Error: #{e.message}", true)
        raise
      end

    end

    t.abort_on_exception = true

  end


  #### Look for scanned files to convert ##################################################################
  def prepare_upload_thread

    @scann_converter_terminate = false
    @scann_converter_running = true
    sleep_count = 0

    t = Thread.new do

      check_program('empty-page'); check_program('unpaper'); check_program('convert')


      until @scann_converter_terminate do
        sleep 1; sleep_count = sleep_count + 1
        if sleep_count > 150 then
          @scann_converter_terminate = true
        end

        scanned_files = Dir.glob(@doc_name_prefix + "*.scanned.ppm").sort_by { |f| File.basename(f) }

        scanned_files.each do |f_scanned_ppm|
          sleep_count = 0

          unless system "empty-page -p 0.6 -i '#{f_scanned_ppm}'"
            f = f_scanned_ppm.split('.')[0] #name without extension

            if @scanned_documents.index(f).nil?
              scanner_status_update("Process: Cleaning")

              puts "Start unpaper with speed-option: #{@unpaper_speed.to_s}"

              if @unpaper_speed
                ### quick version for unpaper, not using --no-mask-scan
                res1 = %x[unpaper -v --overwrite  --post-size a4 --sheet-size a4 --no-grayfilter --no-mask-scan --no-blackfilter  --pre-border 0,120,0,0 '#{f_scanned_ppm}' '#{f}.unpaper.ppm']
              else
                res1 = %x[unpaper -v --overwrite  --post-size a4 --sheet-size a4 --no-grayfilter --no-blackfilter  --pre-border 0,120,0,0 '#{f_scanned_ppm}' '#{f}.unpaper.ppm']
              end

              puts res1
#                raise "Error unpaper - #{res1}" unless File.exist?("#{f}.unpaper.ppm")
#                raise "Error unpaper - #{res1}" unless res1[0..10] == "unpaper 6.1"

              puts "Start convert"
              res2 = %x[convert '#{f}.unpaper.ppm' '#{f}.converted.jpg']
              raise "Error convert - #{res2}" unless res2 == ''

              puts "Start convert to small image"
              res3 = %x[convert '#{f}.converted.jpg' -resize 350x490\! jpg:'#{f}.converted_small.jpg']
              raise "Error convert - #{res3}" unless res3 == ''

              scanner_status_update("Upload to server")
              @scanned_documents.push(f)

              ppm_file = File.open(f_scanned_ppm) if @unpaper_speed ###send the orignal file if unpaper

              RestClient.post @web_server_uri + '/create_from_scanner_jpg', {
                  :upload_file => File.new(f + ".converted.jpg", 'rb'),
                  :small_upload_file => File.new(f + ".converted_small.jpg", 'rb')}


              res4 = FileUtils.rm "#{f}.unpaper.ppm"

              scanner_status_update(" #{@scanned_documents.count()} documents processed.")

              if SIMULATE
                @scann_converter_terminate = true
                @scann_printer_terminate = true
                puts "Done, send one"
              end
            end
          end
        res6 = FileUtils.rm f_scanned_ppm unless SIMULATE
        end

        puts "--check for new work"

      end

      @scann_converter_running = false
      puts '-- terminate convert thread -no new work'
      sleep 0.5
    end
    t.abort_on_exception = true
    t
  end

  def scanner_build_command(device, color)
    @result = '-'

    @doc_name_index = @doc_name_index.next
    scan_tmp_file = @doc_name_prefix + "_#{@doc_name_index}_%03d.scanned.ppm"
    mode = 'Gray' if not color
    mode = 'Color' if color
    resolution = '300'
#    resolution='600' if @resolution_high.checked?
    source = "'ADF Duplex'"
#    source="'ADF Front'" if @scan_only

## Scan file will look like:


    scan = ""

    ["scanimage",
     "--device=" + device,
     "--mode=" + mode,
     "--contrast=" + "70",
     "--brightness=" + "40",
     "--resolution=" + resolution,
     "--format=" + "pnm",
     "--batch=" + scan_tmp_file,
     "--source=" + source,
     "2>&1"].each { |c| scan = scan + c + " " }

    puts "Scan Command: #{scan}"

    return scan

  end

  def scanner_status_update(message, scan_complete = false)
    puts "DRBSCANNER: #{message}"
    RestClient.post @web_server_uri + '/scan_status', {:message => message, :scan_complete => scan_complete}
  end


end
