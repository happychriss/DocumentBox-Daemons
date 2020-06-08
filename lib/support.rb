module Support

  def check_program(command)
    puts "Check command #{command}.."

    if linux_program_exists?(command)
      puts "..OK"
    else
      raise "Processor-Client *#{command}* command missing"
    end

  end

  def linux_program_exists?(command)
    return false if %x[which '#{command}']==''
    true
  end

  def alive?
     true
  end



end

