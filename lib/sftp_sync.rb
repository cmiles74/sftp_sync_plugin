#
# Provides an object for synchronizing a local directory with a remote
# SFTP location.
#
class SftpSync

  require 'rubygems' # only for testing outside of rails
  require 'net/ssh'
  require 'net/sftp'
  require 'ftools'
  require 'log4r'
  include Log4r

  # Attributes for holding our connection and syncing information
  attr_accessor :local_directory
  attr_accessor :remote_host, :remote_directory
  attr_accessor :remote_username, :remote_password

  # Creates a new SFTPSync object.
  #
  # remote_host:: The remote server
  # remote_username:: The username on the remote host
  # remote_password:: The password on the remote host
  def initialize(remote_host, remote_username, remote_password)

    # setup our console logger
    format = PatternFormatter.new(:pattern => "%l:\t %m")
    @log = Log4r::Logger.new('SftpSync')
    @log.add(Log4r::StdoutOutputter.new('console', :formatter=>format))
    
    # save all of our variables
    @remote_host = remote_host
    @remote_username = remote_username
    @remote_password = remote_password
  end

  # Removes the directory and all of child files associated with
  # it. Note that you do not need to always be deleting both a remote
  # and a local path, you can do either one or both.
  #
  # sftp_session:: The sftp_session used to remove remote directories
  # remote_path:: The remote path to remove
  # local_path:: The local path to remove
  def remove_dir(sftp_session, remote_path, local_path)

    if local_path

      # remove the local directory
      FileUtils.remove_dir(local_path)
    elsif remote_path

      # remove all of the files in the remote location
      sftp_session.dir.foreach(remote_path) do |remote_entry|

        # don't remove the links to the current or parent directory
        if(remote_entry.name != "." && remote_entry.name != "..")

          if remote_entry.directory?

            remove_dir(sftp_session, remote_path + "/" + remote_entry.name, nil)
          else

            remove_file(sftp_session, remote_path + "/" + remote_entry.name,
                        nil)
          end
        end
      end
      
      # remove the remote directory, we block in case this is a
      # recursive call and the parent directory is going to be deleted
      # when this call returns
      sftp_session.rmdir!(remote_path)
    end
  end

  # Removes the file. Note that you do not need to always be deleting
  # both a remote and a local path, you can do either one or both.
  #
  # sftp_session:: The sftp_session used to remove remote files
  # remote_path:: The remote path to remove
  # local_path:: The local path to remove
  def remove_file(sftp_session, remote_path, local_path)

    if local_path

      # remove the local file
      FilUtils.remove(local_path)
    elsif remote_path

      # remote the remote file, we need to block on this in case the
      # parent directory is removed next.
      sftp_session.remove!(remote_path)
    end
  end
  
  def push_file(sftp_session, remote_path, local_path)

  end

  # Downloads the file from the remote path to the provided local
  # path.
  #
  # sftp_session:: The sftp_session used to download the file
  # remote_path:: The location of the file to download
  # local_path:: The destination of the downloaded file
  def pull_file(sftp_session, remote_path, local_path)

    sftp_session.download(remote_path, local_path)
  end
  
  def push_dir(sftp_session, remote_path, local_path, delete)

  end

  # Downloads all of the files and directories from the remote path to
  # the local path. If the "delete" flag is set, files in the local
  # location that are not present in the remote location will be
  # removed.
  #
  # sftp_session:: The sftp_session used to download files
  # remote_path:: The remote path to download files from
  # local_path:: The destination of the downloaded files
  def pull_dir(sftp_session, remote_path, local_path, delete)
    
    # make sure the local path exists
    if !File.exists?(local_path)

      File.makedirs(local_path)
    end
    
    # move our local file pointer to the local path
    FileUtils.cd(local_path)

    # get a list of local files
    local_entries = Dir.glob("*")

    # list of items in this directory that we have handled
    handled_local_entry_paths = Array.new

    # enumerate the remote directory
    sftp_session.dir.foreach(remote_path) do |remote_entry|

      # don't sync the link to the local or parent directory
      if(remote_entry.name != "." && remote_entry.name != "..")

        # compute the local path and remote paths
        local_entry_path = local_path + "/" + remote_entry.name
        remote_entry_path = remote_path + "/" + remote_entry.name

        if remote_entry.directory?

          pull_dir(sftp_session, remote_entry_path, local_entry_path, delete)
        else

          pull_file(sftp_session, remote_entry_path, local_entry_path)
        end

        # add the local path to our list of handled paths
        handled_local_entry_paths << local_entry_path
      end
    end

    # handle deletion of stale local files and directories
    if delete

      # loop through the local entries
      local_entries.each do |local_entry|

        # compute the local path
        local_entry_path = local_path + "/" + local_entry

        # check to see if we have handled this path
        if !handled_local_entry_paths.include?(local_entry_path)

          # this entry wasn't on the remote side, delete it
          if File.directory?(local_entry_path)

            remove_dir(sftp_session, nil, local_entry_path)
          else

            remove_file(sftp_session, nil, local_entry_path)
          end
        end
      end
    end
  end

  # Synchronizes the remote and local locations by downloading files
  # from the remote location that are not present in the local
  # location. If delete_local is set to true, files that are present
  # in the local location but not the remote location are deleted.
  #
  # remote_path:: The path to the remote location
  # local_path:: The path to the local location
  # delete:: Flag to indicate if local files that are not
  # present in the remote location should be deleted
  def pull(remote_path, local_path, delete)

    Net::SFTP.start(@remote_host,
                  @remote_username,
                  :password => @remote_password) do |sftp|

      pull_dir(sftp, remote_path, local_path, delete)
    end
  end

  # Synchronizes the remote and local locations by uploading files
  # from the local location that are not present in the remote
  # location. If delete_remote is set to true, files that are present
  # in the remote location but are not present in the local location
  # are deleted.
  #
  # remote_path:: The path to the remote location
  # local_path:: The path to the local location
  # delete:: Flag to indicate if remote files that are not present in
  # the local location should be deleted
  def push(remote_path, local_path, delete)

    Net::SFTP.start(@remote_host,
                  @remote_username,
                  :password => @remote_password) do |sftp|

      push_dir(sftp, remote_path, local_path, delete)
    end
  end
end
