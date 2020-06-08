require_relative '../lib/support'

class Converter

  CONV_FLAG_PDF_AS_ORG = 1
  CONV_FLAG_AS_LETTER = 2


  include Support

  def initialize(web_server_uri, options)
    @web_server_uri = web_server_uri
    @ocr_abby_available = linux_program_exists?('abbyyocr11')
    @ocr_tesseract_available = linux_program_exists?('tesseract')
    @libreoffic_available = linux_program_exists?('libreoffice')
    puts "********* Init Converter with: #{@web_server_uri} / Abby-OCR:#{@ocr_abby_available} / Tesseract-OCR:#{@ocr_tesseract_available}* / LibreOffice:#{@libreoffic_available}******"
    @unpaper_speed = options[:unpaper_speed] == 'y'
  end


  ################## Called from DRB ###################################################

  def run_conversion(data_jpg, mime_type, convert_flags, page_id)


    begin
      t = Thread.new do

        begin
          convert_data(data_jpg, mime_type,convert_flags , page_id)
        rescue => e
          puts "************ ERROR *****: #{e.message}"
          converter_status_update("ERROR:#{e.message}")
          raise
        end

      end

      t.abort_on_exception = true
    end

  end


  ################ Do all the work #########################

  def convert_data(data_jpg, mime_type, convert_flags, page_id)

    begin

      f_org = Tempfile.new("cd2_remote")
      f_org.write(data_jpg)
      f_org.untaint #avoid ruby insecure operation: http://stackoverflow.com/questions/12165664/what-are-the-rubys-objecttaint-and-objecttrust-methods
      fpath = f_org.path #full path to the file to be processed


      puts "********* Start operation Page:#{page_id} / mime_type: #{mime_type.to_s}  and tempfile #{fpath} in folder #{Dir.pwd}*************"
      puts "Flag - Return PDF as Orginal:"+flag?(convert_flags, CONV_FLAG_PDF_AS_ORG).to_s
      puts "Flag - Treat as Letter (not image):"+flag?(convert_flags,CONV_FLAG_AS_LETTER).to_s
      puts "AbbyyOCR available: #{@ocr_abby_available}"

      converter_status_update("-")

      result_txt = ''
      result_sjpg = nil
      result_jpg = nil

      ############################################################## PDF File ###############################################
      ### create preview images, scan pdf for text

      if [:PDF].include?(mime_type)

        check_program('convert')
        puts "------------ Start pdf convertion: Source: '#{fpath}' Target: '#{fpath + '.conv'}'----------"

        result_sjpg = convert_sjpg(fpath)
        result_jpg = convert_jpg(fpath)

        converter_upload_preview_jpgs(result_jpg, result_sjpg, page_id)

        ## only abby OCD supports PDF as input for OCR
        if @ocr_abby_available then

          check_program('abbyyocr11')
          converter_status_update("PDF-Abby")

          exec("abbyyocr11 -f TextUnicodeDefaults -trl -rl German GermanNewSpelling  -if '#{fpath}' -of '#{fpath}.conv.txt'")

          result_txt = read_txt_from_conv_txt(fpath.untaint + '.conv.txt')

          converter_upload_page(result_txt, File.open(fpath), "", page_id)

        else
          puts "********** AbbyyOCR not available"
        end

        ############################################################## JPG File ###############################################
        ### Source is Scanner / Upload from Mobile / Upload from PC

      elsif [:JPG].include?(mime_type) then

        check_program('convert'); check_program('pdftotext'); check_program('unpaper'); check_program('gs')
        fopath = fpath + '.conv'

        ## center the picture, set-up correct densitiy and picture size, to have A4 format  - https://www.scantips.com/calc.html
        puts "------------ Start conversion for jpg: Source: '#{fpath}' Target: '#{fopath}'----------"
        exec("convert '#{fpath}'[0] -auto-orient '#{fopath}.orient'") ##needs to run separate

        if flag?(convert_flags,CONV_FLAG_AS_LETTER)
          puts "------------ Process as normal page with contrast enhancement ----------"
          exec("convert '#{fopath}.orient' -auto-level -normalize -brightness-contrast 30x70 '#{fopath}.orient'")
        end

        exec("convert '#{fopath}.orient' -resize 2480x3507 -background white -gravity center -extent 2480x3507 -density 300  #{fopath}.ppm")
        exec("unpaper --overwrite  --post-size a4 --sheet-size a4 --no-grayfilter --no-blackfilter  --pre-border 0,120,0,0 '#{fopath}.ppm' '#{fopath}.unpaper'")
        exec("convert '#{fopath}.unpaper' jpg:'#{fopath}'")

        ### Upload preview images
        result_sjpg = convert_sjpg(fopath)
        result_jpg = convert_jpg(fopath)
        converter_upload_preview_jpgs(result_jpg, result_sjpg, page_id)

        #### Use Abby if available ###########################
        if @ocr_abby_available

          check_program('abbyyocr11')
          converter_status_update("JPG-Abby")
          exec("abbyyocr11 -f PDF -rl German GermanNewSpelling -ior -ppsm UserDefined -ppw 11906 -pph 16838 -ibfc 16777215 -pacm Pdfa_3a -if '#{fopath}' -of '#{fopath}.pdf'")

          #### Otherwise use tesseract  ###########################
        elsif @ocr_tesseract_available

          check_program('tesseract')
          converter_status_update("JPG-Tesser")

          ## create outputfile with fixed name xxxx.conv.pdf
          exec("tesseract -l deu '#{fopath}' '#{fopath}' pdf")

        end

        if @ocr_tesseract_available or @ocr_abby_available

          puts "Start pdftotxt..."
          ## Extract text data and store in database
          exec("pdftotext -layout '#{fopath + '.pdf'}' #{fopath + '.txt'}")
          result_txt = read_txt_from_conv_txt(fopath + '.txt')

          if flag?(convert_flags, CONV_FLAG_PDF_AS_ORG)
            puts "Return normal Converted PDF, no JPG"
            converter_upload_page(result_txt, File.open(fopath+ '.pdf'), "", page_id)
          else
            puts "Return normal JPG as original + PDF- Uploaded"
            converter_upload_page(result_txt, File.open(fpath), File.open(fopath+ '.pdf'), page_id)
          end
        end

        ############################################################## JPG File ###############################################

      elsif [:MS_EXCEL, :MS_WORD, :ODF_CALC, :ODF_WRITER].include?(mime_type) then

        tika_path = File.join(Dir.pwd, "lib", "tika-app-1.4.jar")

        check_program('convert'); check_program(tika_path) ##jar can be called directly

        ############### Create Preview Pictures of uploaded file

        puts "------------ V2 Start conversion for pdf or jpg: Source: '#{fpath}' ----------"

        ## Tika ############################### http://tika.apache.org/
        exec("java -jar #{tika_path} -h '#{fpath}' >> #{fpath + '.conv.html'}")
        converter_status_update("Office-Tika")
        exec("convert '#{fpath + '.conv.html'}'[0] jpg:'#{fpath + '.conv.tmp'}'") #convert only first page if more exists
        result_sjpg = convert_sjpg(fpath, '.conv.tmp')
        result_jpg = convert_jpg(fpath, '.conv.tmp')

        converter_upload_preview_jpgs(result_jpg, result_sjpg, page_id)

        ################ Extract Text from uploaded file
        puts "Start tika to extract text V2..."
        exec("java -jar #{tika_path} -t '#{fpath}' >> #{fpath + '.conv.txt'}")
        result_txt = read_txt_from_conv_txt(fpath + '.conv.txt')

        ############### If libreoffice available convert document to PDF
        pdf_path = ""

        if @libreoffic_available
          puts "Start LibreOffice to create PDF"
          exec("libreoffice --headless --invisible --convert-to pdf --outdir '#{File.dirname(fpath)}' '#{fpath}'")
          pdf_path = fpath + '.pdf'
        end

        ### Return orginal Excel... and PDF version
        converter_upload_page(result_txt, File.open(fpath), File.open(pdf_path), page_id)

      else
        raise "Unkonw mime -type  *#{mime_type}*"
      end

      puts "Clean-up with: #{fpath + '*'}..."
      #### Cleanup and return
      Dir.glob(fpath + '*').each do |l|
        l.untaint
        File.delete(l)
      end
      puts "ok"
      puts "--------- Completed and  file deleted------------"

    rescue Exception => e
      puts "Error:" + e.message
      return nil, nil, nil, nil, "Error:" + e.message
    end
  end

  ####################################################################################################
  # Support functions
  ####################################################################################################
  def read_txt_from_conv_txt(fpath)
    puts "    start reading textfile"
    result_txt = ''
    File.open(fpath, 'r') { |l| result_txt = l.read }
    puts "ok"
    return result_txt
  end

  def convert_jpg(fpath, source_extension = '')
    puts "Start converting to jpg..."
    res = %x[convert '#{fpath + source_extension}'[0]   -flatten -resize x770 jpg:'#{fpath + '.small.jpg'}'] #convert only first page if more exists
    result_jpg = File.open(fpath + '.small.jpg')
    puts "ok"
    result_jpg
  end

  def convert_sjpg(fpath, source_extension = '')
    puts "Start converting to sjpg..."
    res = %x[convert '#{fpath + source_extension}'[0]  -flatten -resize 350x490\! jpg:'#{fpath + '.small.sjpg'}'] #convert only first page if more exists
    result_sjpg = File.open(fpath + '.small.sjpg')
    puts "ok"
    result_sjpg
  end

  def flag?(value,flag)
    (value & flag)==flag
  end

  ##################################### Upload back to server when completed

  def converter_upload_preview_jpgs(result_jpg, result_sjpg, page_id)
    puts "*** Upload JPGS to #{@web_server_uri} via convert_upload_jpgs"
    RestClient.post @web_server_uri + '/convert_upload_preview_jpgs', {:page => {:result_sjpg => result_sjpg, :result_jpg => result_jpg, :id => page_id}}
  end

  def converter_upload_page(text, org_data, pdf_data, page_id)
    puts "*** Upload text from PDF to #{@web_server_uri} via convert_upload_pdf"
    RestClient.post @web_server_uri + '/convert_upload_pdf', {:page => {:content => text, :org_data => org_data, :pdf_data => pdf_data, :id => page_id}}
    converter_status_update("ok")
  end

  def exec(command)
    res = %x[#{command} 2>&1]
    puts "Command:"+ command + "-" + res
  end

  ##################################### Update Status

  def converter_status_update(message)
    puts "DRBCONVERTER: #{message}"
    RestClient.post @web_server_uri + '/convert_status', {:message => message}
  end


  private :read_txt_from_conv_txt, :convert_jpg, :convert_sjpg, :converter_status_update, :converter_upload_preview_jpgs, :converter_upload_page
end
