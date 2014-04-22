class PipelineInstance < ArvadosModel
  include AssignUuid
  include KindAndEtag
  include CommonApiTemplate
  serialize :components, Hash
  serialize :properties, Hash
  serialize :components_summary, Hash
  belongs_to :pipeline_template, :foreign_key => :pipeline_template_uuid, :primary_key => :uuid

  before_validation :bootstrap_components
  before_validation :update_success
  before_validation :verify_status
  before_create :set_state_before_save
  before_save :set_state_before_save

  api_accessible :user, extend: :common do |t|
    t.add :pipeline_template_uuid
    t.add :pipeline_template, :if => :pipeline_template
    t.add :name
    t.add :components
    t.add :success
    t.add :active
    t.add :dependencies
    t.add :properties
    t.add :state
    t.add :components_summary
  end

  # Supported states for a pipeline instance
  New = 'New'
  Ready = 'Ready'
  RunningOnServer = 'RunningOnServer'
  RunningOnClient = 'RunningOnClient'
  Paused = 'Paused'
  Failed = 'Failed'
  Complete = 'Complete'

  def dependencies
    dependency_search(self.components).keys
  end

  # if all components have input, the pipeline is Ready
  def components_look_ready?
    if !self.components || self.components.empty?
      return false
    end

    all_components_have_input = true
    self.components.each do |name, component|
      component['script_parameters'].each do |parametername, parameter|
        parameter = { 'value' => parameter } unless parameter.is_a? Hash
        if parameter['value'].nil? and parameter['required']
          if parameter['output_of']
            next
          end
          all_components_have_input = false
          break
        end
      end
    end
    return all_components_have_input
  end

  def progress_table
    begin
      # v0 pipeline format
      nrow = -1
      components['steps'].collect do |step|
        nrow += 1
        row = [nrow, step['name']]
        if step['complete'] and step['complete'] != 0
          if step['output_data_locator']
            row << 1.0
          else
            row << 0.0
          end
        else
          row << 0.0
          if step['failed']
            self.success = false
          end
        end
        row << (step['warehousejob']['id'] rescue nil)
        row << (step['warehousejob']['revision'] rescue nil)
        row << step['output_data_locator']
        row << (Time.parse(step['warehousejob']['finishtime']) rescue nil)
        row
      end
    rescue
      []
    end
  end

  def progress_ratio
    t = progress_table
    return 0 if t.size < 1
    t.collect { |r| r[2] }.inject(0.0) { |sum,a| sum += a } / t.size
  end

  def self.queue
    self.where('active = true')
  end

  protected
  def bootstrap_components
    if pipeline_template and (!components or components.empty?)
      self.components = pipeline_template.components.deep_dup
    end
  end

  def update_success
    if components and progress_ratio == 1.0
      self.success = true
    end
  end

  def dependency_search(haystack)
    if haystack.is_a? String
      if (re = haystack.match /^([0-9a-f]{32}(\+[^,]+)*)+/)
        {re[1] => true}
      else
        {}
      end
    elsif haystack.is_a? Array
      deps = {}
      haystack.each do |value|
        deps.merge! dependency_search(value)
      end
      deps
    elsif haystack.respond_to? :keys
      deps = {}
      haystack.each do |key, value|
        deps.merge! dependency_search(value)
      end
      deps
    else
      {}
    end
  end

  def verify_status
    if active_changed?
      if self.active
        self.state = RunningOnServer
      else
        if self.components_look_ready?
          self.state = Ready
        else
          self.state = New
        end
      end
    elsif success_changed?
      if self.success
        self.active = false
        self.state = Complete
      else
        self.active = false
        self.state = Failed
      end
    elsif state_changed?
      case self.state
      when New, Ready, Paused
        self.active = false
        self.success = nil
      when RunningOnServer
        self.active = true
        self.success = nil
      when RunningOnClient
        self.active = false
        self.success = nil
      when Failed
        self.active = false
        self.success = false
        self.state = Failed   # before_validation will fail if false is returned in the previous line
      when Complete
        self.active = false
        self.success = true
      else
        return false
      end
    elsif components_changed? 
      if !self.state || self.state == New || !self.active
        if self.components_look_ready?
          self.state = Ready
        else
          self.state = New
        end
      end
    end
  end

  def set_state_before_save
    if !self.state || self.state == New
      if self.active
        self.state = RunningOnServer
      elsif self.components_look_ready?
        self.state = Ready
      else
        self.state = New
      end
    end
  end

end
