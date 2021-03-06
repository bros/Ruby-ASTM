require "active_support/all"

module LabInterface

	ACK = "\x06"
  ENQ = "\x05"
  STX = "\x02"
  LF = "\x10"
  CR = "\x13"
  ETX = "\x03"
  EOT = "\x04"


  mattr_accessor :ethernet_server
  mattr_accessor :server_ip
  mattr_accessor :server_port
  mattr_accessor :serial_port
  mattr_accessor :serial_baud
  mattr_accessor :serial_parity
  mattr_accessor :usb_port
  mattr_accessor :usb_baud
  mattr_accessor :usb_parity
  mattr_accessor :mid_frame_end_detected

  ## gather bytes to store for us to test.
  mattr_accessor :test_data_bytes



  mattr_accessor :headers
  mattr_accessor :mapping
  mattr_accessor :respond_to_queries

  ## buffer of incoming data.
  mattr_accessor :data_buffer
    

  ## returns the root directory of the gem.
  def root
      File.dirname __dir__
  end

  ## can process a file which contains ASTM output.
  ## this method is added so that you can load previously generated ASTM output into your database
  ## it also simplifies testing.
  def process_text_file(full_file_path)
    #full_file_path ||= File.join root,'../test','resources','sysmex_550_sample.txt'
    IO.read(full_file_path).each_line do |line|
      line.split('\\r').each do |txt| 
        process_text(txt)
      end
    end
  end




  def terminator
    "L|1|N\r"
  end


  def checksum(input)
    strString = input
    checksum = strString.sum
    b = checksum.to_s(16)
    strCksm = b[-2..-1]
    if strCksm.length < 2 
      for i in strString.length..1
         strCksm = "0" + strCksm
      end
    end
    strCksm.upcase
  end

  def generate_response
    header_responses = self.headers[-1].build_one_response
    header_responses.each_with_index {|response,key|
      message_checksum = checksum(response + terminator + ETX)
      final_resp = STX + response + terminator + ETX + message_checksum + "\r" 
      final_resp_arr = final_resp.bytes.to_a
      final_resp_arr << 10
      if (self.headers[-1].response_sent == false)
        puts "sending the  data as follows----------------------------------------------"
        puts "response sent is:"
        puts self.headers[-1].response_sent
        puts final_resp_arr.to_s
        puts final_resp_arr.pack('c*').gsub(/\r/,'\n')
        send_data(final_resp_arr.pack('c*')) 
        self.headers[-1].response_sent = true if (key == (header_responses.size - 1))
      else
        puts "sending EOT"
        send_data(EOT)
      end
    }
  end

  def is_mid_frame_end?(bytes_array)

    ## if you get 13,10,2 anywhere, ignore that and the subsequent digit.
    bytes_indices_to_delete = []
    unless bytes_array.blank?
      bytes_array.each_with_index{|val,key|
        if bytes_array.size >= (key + 2)
          if bytes_array[key..(key+2)] == [13,10,2]
            bytes_indices_to_delete.push(key - 3)
            bytes_indices_to_delete.push(key - 2)
            bytes_indices_to_delete.push(key - 1)
            bytes_indices_to_delete.push(key)
            bytes_indices_to_delete.push(key + 1)
            bytes_indices_to_delete.push(key + 2)
          end
        end
      }
    end
    bytes_indices_to_delete
  end

  def pre_process_bytes(byte_arr,concat)

      puts byte_arr.to_s
      indices_to_delete = is_mid_frame_end?(byte_arr)
      #puts "indices to delete"
      #puts indices_to_delete.to_s

      if self.mid_frame_end_detected == true
        #puts "deletected mid fram is true, so deleting first byte before delete"
        #puts byte_arr.to_s
        byte_arr = byte_arr[1..-1]
        #puts "after deleteing"
        #puts byte_arr.to_s
        self.mid_frame_end_detected = false
      end

      unless indices_to_delete.blank?
        if byte_arr[(indices_to_delete[-1] + 1)]
          #puts "before deleting frame number "
          #puts byte_arr.to_s
          byte_arr.delete_at((indices_to_delete[-1] + 1))
          #puts "after deleting"
          #puts byte_arr.to_s
        else
          self.mid_frame_end_detected = true
        end
      end
      #puts "byte arr before reject"
      byte_arr = byte_arr.reject.with_index{|c,i|  indices_to_delete.include? i}
      

      byte_arr.each do |byte|
        x = [byte].pack('c*').force_encoding('UTF-8')
        if x == "\r"
          concat+="\n"
        elsif x == "\n"
          #puts "new line found --- "
          concat+=x
          #puts "last thing in concat."
          #puts concat[-1].to_s
        else
          concat+=x
        end
      end

      concat

  end

	def receive_data(data)
      

    begin


      self.data_buffer ||= ''

      #puts "incoming data bytes."

      concat = ""
      
   
      byte_arr = data.bytes.to_a
      self.test_data_bytes ||= []
      self.test_data_bytes.push(byte_arr)
    
      concat = pre_process_bytes(byte_arr,concat)

     
      
      #puts "concat is:"
      
      #puts concat.to_s
      
      self.data_buffer << concat

      ## if the last byte is EOT, then call process text.
      ## inside that split by line and process one at a time.
      ##process_text(concat)      
      

      if data.bytes.to_a[-1] == 4
        #puts "GOT EOT --- PROCESSING BUFFER, AND CLEARING."
        process_text(self.data_buffer)
        #root_path = File.dirname __dir
        #puts "root path #{root_path}"
        #IO.write((File.join root_path,'test','resources','roche_multi_frame_bytes.txt'),self.test_data_bytes.to_s)
        #puts self.test_data_bytes.flatten.to_s
        self.data_buffer = ''
        if self.headers[-1].queries.blank?
          #puts "no queries in header so sending ack after getting EOT and processing the buffer"
          send_data(ACK)
        else
          #puts "sending ENQ"
          send_data(ENQ)
        end
      elsif data.bytes.to_a[0] == 6
        #puts "GOT ACK --- GENERATING RESPONSE"
        unless self.headers.blank?
          header_responses = self.headers[-1].build_one_response({machine_name: self.headers[-1].machine_name})
          ## if no queries then, we have to send ack.
          if header_responses.blank?
            #puts "sending ACK since there are no queries in the header"
            send_data(ACK)
          end
          header_responses.each_with_index {|response,key|
            message_checksum = checksum(response + terminator + ETX)
            final_resp = STX + response + terminator + ETX + message_checksum + "\r" 
            final_resp_arr = final_resp.bytes.to_a
            final_resp_arr << 10
            if (self.headers[-1].response_sent == false)
              #puts "sending the  data as follows----------------------------------------------"
              #puts "response sent is:"
              #puts self.headers[-1].response_sent
              #puts final_resp_arr.pack('c*').gsub(/\r/,'\n')
              send_data(final_resp_arr.pack('c*')) 
              self.headers[-1].response_sent = true if (key == (header_responses.size - 1))
            else
              #puts "sending EOT"
              send_data(EOT)
            end
          }
        else
          #puts "NO HEADERS PRESENT --- "
        end
      elsif data.bytes.to_a[0] == 255
        #puts  " ----------- got 255 data -----------, not sending anything back. "
      else
        #unless self.data_buffer.blank?
        #  puts self.data_buffer.gsub(/\r/,'\n').to_s
        #end
        ## send the header 
        #puts "--------- SENT ACK -----------"
        if self.data_buffer =~ /MSH\|/
          #puts " -------------- HEADERS ARE BLANK WITH HL7, sending ack. ------------ "
          process_text(self.data_buffer)
          self.data_buffer = ''
          if self.headers.size > 0
            self.headers[-1].commit
            send_data(self.headers[-1].generate_ack_success_response)
          end
        else
          #puts " -------------- HEADERS ARE BLANK NOT HL7, sending ack. ------------ "
          send_data(ACK)
        end
      end

    rescue => e
      #self.headers = []
      AstmServer.log("data was: " + self.data_buffer + "error is:" + e.backtrace.to_s)
      #send_data(EOT)
    end

  end

  def send_enq
    #puts "enq as bytes is:"
    #puts ENQ.unpack('c*')
    send_data(ENQ)
  end

  def process_text(text)
      puts "text is:"
      puts text
      text.split("\n").each do |l|
        puts "doing line:#{l}" 
		    line = Line.new({:text => l})
        process_type(line)
      end
  end

  def process_type(line)
      case line.type
      when "Hl7_Header"
        hl7_header = Hl7Header.new({:line => line})
        self.headers ||= []
        self.headers << hl7_header
      when "Hl7_Observation"
        unless self.headers[-1].patients.blank?
          unless self.headers[-1].patients[-1].orders[-1].blank?
            hl7_observation = Hl7Observation.new({:line => line})
            self.headers[-1].patients[-1].orders[-1].results[hl7_observation.name] ||= hl7_observation
          end
        end
      when "Hl7_Patient"
        hl7_patient = Hl7Patient.new({:line => line})
        self.headers[-1].patients << hl7_patient
      when "Hl7_Order"
        unless self.headers[-1].patients.blank?
          hl7_order = Hl7Order.new({:line => line, :patient_id => self.headers[-1].patients[-1].patient_id})
          self.headers[-1].patients[-1].orders << hl7_order
        end
      when "Header"
        puts "got header"
        header = Header.new({:line => line})
        self.headers ||= []
        self.headers << header
      when "Query"
        puts "got query"
        query = Query.new({:line => line})
        self.headers[-1].queries << query
      when "Patient"
        puts "got patient."
        patient = Patient.new({:line => line})
        self.headers[-1].patients << patient
      when "Order"
        order = Order.new({:line => line})
        self.headers[-1].patients[-1].orders << order
      when "Result"
        result = Result.new({:line => line})
        self.headers[-1].patients[-1].orders[-1].results[result.name] ||= result
      when "Terminator"
        ## it didn't terminate so there was no commit being called.
        puts "got terminator."
        self.headers[-1].commit
      end
  end

=begin
1.STX + response + LF + ETX
2.response
3.STX + response + "L|1|N\r" + ETX 
4.response + "L|1|N\r" 
=end
  def unbind
     puts "-- someone disconnected from the echo server!"
  end

end