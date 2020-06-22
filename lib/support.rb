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

  def shell_exec(step,command)
    puts "ShellExec[#{step}]: #{command}"
    Open3.popen3(command) do |stdin, stdout, stderr, thread|
      err_txt=stderr.read.chomp
      unless err_txt==""
        puts "ERROR: #{err_txt}"
        raise "Shell-Exec - error on "+step+":"+ err_txt
      end
    end
  end


end

