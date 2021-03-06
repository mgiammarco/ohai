#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: GNU GPL, Version 3
#
# Copyright (C) 2008, Opscode Inc. 
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

require 'ohai/exception'
require 'ohai/config'
require 'ohai/log'
require 'tmpdir'
require 'fcntl'
require 'etc'
require 'systemu'

module Ohai
  module Mixin
    module Command
      
      def run_command(args={})         
        if args.has_key?(:creates)
          if File.exists?(args[:creates])
            Ohai::Log.debug("Skipping #{args[:command]} - creates #{args[:creates]} exists.")
            return false
          end
        end
        
        stdout_string = nil
        stderr_string = nil
                
        args[:cwd] ||= Dir.tmpdir        
        unless File.directory?(args[:cwd])
          raise Ohai::Exception::Exec, "#{args[:cwd]} does not exist or is not a directory"
        end
        
        status = nil
        Dir.chdir(args[:cwd]) do
          if args[:timeout]
            begin
              Timeout.timeout(args[:timeout]) do
                status, stdout_string, stderr_string = systemu(args[:command])
              end
            rescue Exception => e
              Ohai::Log.error("#{args[:command_string]} exceeded timeout #{args[:timeout]}")
              raise(e)
            end
          else
            status, stdout_string, stderr_string = systemu(args[:command])
          end

          # systemu returns 42 when it hits unexpected errors
          if status.exitstatus == 42 and stderr_string == ""
            stderr_string = "Failed to run: #{args[:command]}, assuming command not found"
            Ohai::Log.debug(stderr_string)          
          end

          if stdout_string
            Ohai::Log.debug("---- Begin #{args[:command]} STDOUT ----")
            Ohai::Log.debug(stdout_string.strip)
            Ohai::Log.debug("---- End #{args[:command]} STDOUT ----")
          end
          if stderr_string
            Ohai::Log.debug("---- Begin #{args[:command]} STDERR ----")
            Ohai::Log.debug(stderr_string.strip)
            Ohai::Log.debug("---- End #{args[:command]} STDERR ----")
          end
        
          args[:returns] ||= 0
          args[:no_status_check] ||= false
          if status.exitstatus != args[:returns] and not args[:no_status_check]
            raise Ohai::Exception::Exec, "#{args[:command]} returned #{status.exitstatus}, expected #{args[:returns]}"
          else
            Ohai::Log.debug("Ran #{args[:command_string]} (#{args[:command]}) returned #{status.exitstatus}")
          end
        end
        return status, stdout_string, stderr_string
      end

      module_function :run_command
           
      # This is taken directly from Ara T Howard's Open4 library, and then 
      # modified to suit the needs of Ohai.  Any bugs here are most likely
      # my own, and not Ara's.
      #
      # The original appears in external/open4.rb in it's unmodified form. 
      #
      # Thanks, Ara. 
      def popen4(cmd, args={}, &b)
        
        args[:user] ||= nil
        unless args[:user].kind_of?(Integer)
          args[:user] = Etc.getpwnam(args[:user]).uid if args[:user]
        end
        args[:group] ||= nil
        unless args[:group].kind_of?(Integer)
          args[:group] = Etc.getgrnam(args[:group]).gid if args[:group]
        end
        args[:environment] ||= nil
        
        pw, pr, pe, ps = IO.pipe, IO.pipe, IO.pipe, IO.pipe

        verbose = $VERBOSE
        begin
          $VERBOSE = nil
          ps.last.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)

          cid = fork {
            pw.last.close
            STDIN.reopen pw.first
            pw.first.close

            pr.first.close
            STDOUT.reopen pr.last
            pr.last.close

            pe.first.close
            STDERR.reopen pe.last
            pe.last.close

            STDOUT.sync = STDERR.sync = true

            if args[:user]
              Process.euid = args[:user]
              Process.uid = args[:user]
            end
            
            if args[:group]
              Process.egid = args[:group]
              Process.gid = args[:group]
            end
            
            if args[:environment]
              args[:environment].each do |key,value|
                ENV[key] = value
              end
            end
            
            begin
              if cmd.kind_of?(Array)
                exec(*cmd)
              else
                exec(cmd)
              end
              raise 'forty-two' 
            rescue Exception => e
              Marshal.dump(e, ps.last)
              ps.last.flush
            end
            ps.last.close unless (ps.last.closed?)
            exit!
          }
        ensure
          $VERBOSE = verbose
        end

        [pw.first, pr.last, pe.last, ps.last].each{|fd| fd.close}

        begin
          e = Marshal.load ps.first
          raise(Exception === e ? e : "unknown failure!")
        rescue EOFError # If we get an EOF error, then the exec was successful
          42
        ensure
          ps.first.close
        end

        pw.last.sync = true

        pi = [pw.last, pr.first, pe.first]

        if b 
          begin
            b[cid, *pi]
            Process.waitpid2(cid).last
          ensure
            pi.each{|fd| fd.close unless fd.closed?}
          end
        else
          [cid, pw.last, pr.first, pe.first]
        end
      end      
      
      module_function :popen4
    end
  end
end
