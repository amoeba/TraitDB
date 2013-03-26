module UploadHelper
  ACTIONS_FOR_STATES = {
    'new' => ['Uploaded', 'select_headers'],
    'reading_headers' => ['Reading Headers', 'start_validation'],
    'read_headers' => ['Read Headers', 'validating'],
    'headers_failed' => ['Unable to Read', 'show'],
    'count_failed' => ['Unable to Count Rows', 'show'],
    'counted_rows' => ['Counted Rows', 'start_validation'],
    'validating' => ['Validating Headers', 'validating'],
    'validated' => ['Validated Headers', 'check_rows'],
    'validation_failed' => ['Validation Failed', 'show'],
    'parsing' => ['Parsing Data', 'check_rows'],
    'parsed' => ['Parsed Data', 'check_rows'],
    'parse_warnings' => ['Parsed Data with Warnings', 'check_rows'],
    'importing' => ['Importing Data', 'import_rows'],
    'imported' => ['Imported Data', 'show'],
    'import_failed' => ['Import Failed', 'show']
  }
  def link_to_current_status(dataset)
    if dataset.import_job.nil?
      link_text, action = ACTIONS_FOR_STATES['new']
    else
      link_text, action = ACTIONS_FOR_STATES[dataset.import_job.state]
    end
    link_to(link_text, {:action => action, :id => dataset.id})
  end
end