#
# Provides an object for synchronizing a local directory with a remote
# SFTP location.
#
class SftpSync

  require 'rubygems' # only for testing outside of rails
  require 'net/ssh'
  require 'net/sftp'
  require 'ftools'
  require 'yaml'
  require 'log4r'
  include Log4r

  # Attributes for holding our connection and syncing information
  attr_accessor :local_directory
  attr_accessor :remote_host, :remote_directory
  attr_accessor :remote_username, :remote_password

  # the name of the file where we store our sync data
  SYNC_DATA_FILE = ".sftp_sync_data.yaml"

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

  # Returns a Hash with the last push and pull times for the provided
  # path. This Hash will have the following keys...
  #
  # - push_last_local mtime of the local file after the last push
  # - push_last_remote mtime of the remote file after the last push
  # - pull_last_local mtime of the local files after the last pull
  # - pull_last_remote mtime of the remote file after the last pull
  #
  # sync_data:: The Hash of sync data from which times will be fetched
  # remote_path:: The path for which to fetch times
  def get_last_sync_times(sync_data, remote_path)

    # get our last push and pull times
    push_last = sync_data["push"][remote_path]
    pull_last = sync_data["pull"][remote_path]

    if push_last

      push_last_local = push_last[0]
      push_last_remote = push_last[1]
    else

      push_last_local = nil
      push_last_remote = nil
    end

    if pull_last
      
      pull_last_local = pull_last[0]
      pull_last_remote = pull_last[1]
    else

      pull_last_local = nil
      pull_last_remote = nil
    end

    return Hash["push_last_local" => push_last_local,
                "push_last_remote" => push_last_remote,
                "pull_last_local" => pull_last_local,
                "pull_last_remote" => pull_last_remote]
  end
  
  # Uploades the file from the local path to the remote path.
  #
  # sftp_session:: The sftp_session used to upload the file
  # remote_path:: The destination of the uploaded file
  # local_path:: The location of the file to upload
  # sync_data:: Hash used to track the modification time of pushed files
  def push_file(sftp_session, remote_path, local_path, sync_data)

    # get the modification time of the local file
    local_mtime = File.mtime(local_path)

    # get the remote modification time
    begin

      remote_mtime = Time.at(sftp_session.file.open(remote_path).stat().mtime)
    rescue

      remote_mtime = nil
    end

    # get our last sync times
    last_sync = get_last_sync_times(sync_data, remote_path)
    
    if !remote_mtime || !last_sync["push_last_remote"] ||
        (last_sync["push_last_remote"] <=> remote_mtime) < 0

      # push the file
      sftp_session.upload!(local_path, remote_path)
      @log.debug("Pushed file #{local_path}")

      # get the new modification time of the remote file
      remote_mtime = Time.at(sftp_session.file.open(remote_path).stat().mtime)
      
      # save the modification time of the local file
      sync_data["push"][remote_path] = [local_mtime, remote_mtime]
    else

      @log.debug("Skipped file #{local_path}")
    end
  end

  # Downloads the file from the remote path to the provided local
  # path.
  #
  # sftp_session:: The sftp_session used to download the file
  # remote_path:: The location of the file to download
  # local_path:: The destination of the downloaded file
  # sync_data:: Hash used to track the modification time of pulled files
  def pull_file(sftp_session, remote_path, local_path, sync_data)

    # get the remote modification time
    remote_mtime = Time.at(sftp_session.file.open(remote_path).stat().mtime)

    # get the local modification time
    if File.exists?(local_path)

      local_mtime = File.mtime(local_path)
    else

      local_mtime = nil
    end

    # get our last sync times
    last_sync = get_last_sync_times(sync_data, remote_path)

    if !local_mtime || !last_sync["pull_last_remote"] ||
        (last_sync["pull_last_remote"] <=> remote_mtime) < 0

      # pull the file
      sftp_session.download!(remote_path, local_path)
      @log.debug("Pulled file #{remote_path}")

      # get the new modification time of the remote file
      local_mtime = File.mtime(local_path)
      
      # save the modification time of the remote file
      sync_data["pull"][remote_path] = [local_mtime, remote_mtime]
    else

      @log.debug("Skipped file #{remote_path}")
    end
  end

  # Uploads all of the files and directories from the local path to
  # the remote path. If the "delete" flag is set, files in the remote
  # location that are not present in the local location will be
  # removed.
  #
  # sftp_session:: The sftp_session used to upload the files
  # remote_path:: The remote path that will be the destination of the
  # uploaded files
  # local_path:: The local path of files to upload
  # sync_data:: Hash used to track modification time of pushed files
  def push_dir(sftp_session, remote_path, local_path, delete, sync_data)

    @log.debug("Pushing dir #{local_path}")
    
    # make sure the remote path exists
    begin

      sftp_session.dir.entries(remote_path)
    rescue

      # we block on the directory creation because we'll need it as
      # soon as this call returns
      sftp_session.mkdir!(remote_path)
    end

    # move our local file pointer to the local path
    FileUtils.cd(local_path)

    # get a list of our remote files
    remote_entries = sftp_session.dir.glob(remote_path, "*")

    # a list of items in this directory that we have handled
    handled_remote_entry_paths = Array.new

    # enumerate the local directory
    Dir.glob("*").each do |local_entry|

      # don't sync the link to the local or parent directory
      if(local_entry != "." && local_entry != "..")

        # compute the local and remote paths
        local_entry_path = local_path + "/" + local_entry
        remote_entry_path = remote_path + "/" + local_entry

        if File.directory?(local_entry_path)

          push_dir(sftp_session, remote_entry_path, local_entry_path, delete,
                   sync_data)
        else

          push_file(sftp_session, remote_entry_path, local_entry_path,
                    sync_data)
        end

        # add the remote path to our list of handled paths
        handled_remote_entry_paths << remote_entry_path
      end
    end

    # handle the deletion of stale remote files and directories
    if delete

      # loop through the remote entries
      remote_entries.each do |remote_entry|

        # compute the remote path
        remote_entry_path = remote_path + "/" + remote_entry.name

        # check to see if we have handled this path
        if !handled_remote_entry_paths.include?(remote_entry_path)

          # this entry wasn't on the local side, delete it
          if remote_entry.directory?

            remove_dir(sftp_session, remote_entry_path, nil)
          else

            remove_file(sftp_session, remote_entry_path, nil)
          end
        end
      end
    end

    @log.debug("Pushed dir #{local_path}")
  end

  # Downloads all of the files and directories from the remote path to
  # the local path. If the "delete" flag is set, files in the local
  # location that are not present in the remote location will be
  # removed.
  #
  # sftp_session:: The sftp_session used to download files
  # remote_path:: The remote path to download files from
  # local_path:: The destination of the downloaded files
  # sync_data:: Hash used to track modification time of pulled files
  def pull_dir(sftp_session, remote_path, local_path, delete, sync_data)

    @log.debug("Pulling dir #{remote_path}")
    
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

      # don't sync the link to the local or parent directory or our
      # sync data
      if(remote_entry.name != "." && remote_entry.name != ".." &&
         remote_entry.name != SYNC_DATA_FILE)

        # compute the local path and remote paths
        local_entry_path = local_path + "/" + remote_entry.name
        remote_entry_path = remote_path + "/" + remote_entry.name

        if remote_entry.directory?

          pull_dir(sftp_session, remote_entry_path, local_entry_path, delete,
                   sync_data)
        else

          pull_file(sftp_session, remote_entry_path, local_entry_path,
                    sync_data)
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

    @log.debug("Pulled dir #{remote_path}")
  end

  # Returns the path to the file used for storing sync data. Note taht
  # this path should be a directory, not a file
  #
  # local_path:: Path to the directory where sync data will be or has
  # been stored.
  def get_sync_data_file(local_path)

    # location of our sync data
    sync_data_path = local_path + "/" + SYNC_DATA_FILE

    return sync_data_path
  end
  
  # Loads in our sync data from the provided path and returns that
  # data as a Hash. Note that this path should be a directory, not a
  # file.
  #
  # local_path:: Path to directory containing sync data
  def load_sync_data(local_path)

    # check to see if we have sync data
    if File.exists?(get_sync_data_file(local_path))

      # load in our sync data
      sync_data = YAML::load_file(get_sync_data_file(local_path))
    else

      # start with new sync data
      sync_data = Hash.new
      sync_data["push"] = Hash.new
      sync_data["pull"] = Hash.new
    end

    return sync_data
  end

  # Saves our sync data to the provided path. Note that this path
  # should be a directory, not a file.
  #
  # local_path:: Path to the directory where sync data will be stored
  # sync_data:: The sync data to save
  def save_sync_data(local_path, sync_data)

    # save our sync data
    File.open(get_sync_data_file(local_path), 'w') do |out|

      YAML::dump(sync_data, out)
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

    # load our sync data
    sync_data = load_sync_data(local_path)

    Net::SFTP.start(@remote_host,
                  @remote_username,
                  :password => @remote_password) do |sftp|

      pull_dir(sftp, remote_path, local_path, delete, sync_data)
    end

    # save our sync data
    save_sync_data(local_path, sync_data)
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

    # load our sync data
    sync_data = load_sync_data(local_path)
    
    Net::SFTP.start(@remote_host,
                  @remote_username,
                  :password => @remote_password) do |sftp|

      push_dir(sftp, remote_path, local_path, delete, sync_data)
    end

    # save our sync data
    save_sync_data(local_path, sync_data)
  end
end
