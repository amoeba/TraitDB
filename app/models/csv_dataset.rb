class CsvDataset < ActiveRecord::Base
  attr_accessible :csv_file
  attr_accessible :encoding
  if TraitDB::Application.config.use_s3
    has_attached_file :csv_file,
                      :storage => :s3,
                      :s3_credentials => Rails.root.join('config','s3_credentials.yml')
  else
    has_attached_file :csv_file
  end
  belongs_to :project
  belongs_to :user
  has_one :import_job, :dependent => :destroy
  validates_attachment_presence :csv_file
  validates_attachment_size :csv_file, :greater_than => 0.bytes, :unless => Proc.new { |imports| imports.csv_file_file_name.blank? }
  validates_attachment_content_type :csv_file, :content_type => 'text/csv'
  scope :by_project, lambda{|p| where(:project_id => p) unless p.nil?}

  def status
    return 'new' if import_job.nil?
    import_job.state
  end

  def problem?
    return false if import_job.nil?
    import_job.parse_warnings?
  end

  def failed?
    return false if import_job.nil?
    import_job.failed?
  end

  def imported?
    return false if import_job.nil? || problem? || failed?
    true
  end

  def get_local_file
    # If the file is local, just return the file system path
    if File.exists?(csv_file.path)
      return csv_file.path
    else
      cache_file
      return @cached_file.file
    end
  end

  def file_name
    csv_file_file_name
  end

  def file_cached?
    return false if @cached_file.nil?
    true
  end

  private

  def cache_file
    unless file_cached?
      @cached_file = CachedFile.new(csv_file.url)
    end
  end

end
