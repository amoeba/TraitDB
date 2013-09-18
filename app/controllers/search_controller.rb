class SearchController < ApplicationController
  before_filter :set_project
  OPERATORS = { :or => 'or', :and => 'and' }
  def index
    @iczn_groups = @project.iczn_groups.sorted.select{|group| group.taxa.count > 0}

    @trait_groups = []
    @trait_types = [['Categorical', :categorical], ['Continuous', :continuous]]
    @trait_names = {:categorical => CategoricalTrait.by_project(@project).sorted, :continuous => ContinuousTrait.by_project(@project).sorted }
    @categorical_trait_values = categorical_trait_values_for_trait(@trait_names[:categorical].first)
    # Trait set support
    @trait_set_levels = @project.trait_sets.levels
  end

  def list_taxa # needs iczn_group_id and parent_ids
    iczn_group_id = params[:iczn_group_id]
    parent_ids = params[:parent_ids]
    @taxa_list = taxa_in_iczn_group_with_parents(iczn_group_id, parent_ids)
    render :json => @taxa_list
  end

  # TODO: send trait set ids as params and filter on them!
  def list_categorical_trait_names # needs taxon_ids and optionally trait_set_id
    @categorical_trait_names = []
    @project.taxa.where(:id => params[:taxon_ids]).each do |taxon|
      @categorical_trait_names = @categorical_trait_names | taxon.grouped_categorical_traits # filter on trait set id if provided
    end
    if params[:trait_set_id]
      @categorical_trait_names = @categorical_trait_names.select{|x| x.trait_set_id == Integer(params[:trait_set_id])}
    end
    render :json => @categorical_trait_names
  end

  def list_continuous_trait_names # needs taxon_ids and optionally trait_set_id
    @continuous_trait_names = []
    @project.taxa.where(:id => params[:taxon_ids]).each do |taxon|
      @continuous_trait_names = @continuous_trait_names | taxon.grouped_continuous_traits # Filter on trait_set_id if provided
    end
    if params[:trait_set_id]
      @continuous_trait_names = @continuous_trait_names.select{|x| x.trait_set_id == Integer(params[:trait_set_id])}
    end

    render :json => @continuous_trait_names
  end

  def list_categorical_trait_values
    @trait_values = categorical_trait_values_for_trait(params[:trait_id])
    render :json => @trait_values
  end

  def list_trait_sets # needs parent_trait_set_id, may be nil for project's root trait sets
    @trait_sets = @project.trait_sets.where(:parent_trait_set_id => params[:parent_trait_set_id])
    render :json => @trait_sets
  end

  def results
    @trait_operator = params['trait_operator']
    # trait_operator must be 'and' or 'or'.
    # This string is used in database queries and defaults to 'or'
    unless OPERATORS.values.include? @trait_operator
      @trait_operator = OPERATORS[:or]
    end
    @results = {}
    @results[:columns] = {} # start with an empty hash for output display columns

    analyze_lowest_requested_taxa # populates @lowest_requested_taxa, @selected_taxon_ids, and @results[:columns][:iczn_groups]
    # analyze_lowest_requested_taxa must come before assemble_trait_filters
    assemble_trait_filters # populates @categorical_trait_category_map and @continuous_trait_predicate_map

    # Output columns should include chosen continuous traits
    @results[:columns][:continuous_traits] = @project.continuous_traits.where(:id => @continuous_trait_predicate_map.keys).map do |continuous_trait|
      {:id => continuous_trait.id, :name => continuous_trait.full_name}
    end

    # output columns should include chosen categorical traits
    @results[:columns][:categorical_traits] = @project.categorical_traits.where(:id => @categorical_trait_category_map.keys).map do |categorical_trait|
      {:id => categorical_trait.id, :name => categorical_trait.full_name}
    end

    # Arrays to hold ids of the traits where notes were recorded
    categorical_trait_notes_ids = [] # categorical_trait_ids of traits where notes were found
    continuous_trait_notes_ids = [] # continuous_trait_ids of traits where notes were found

    # Array to hold the metadata field names attached to the data we found
    otu_metadata_field_names = []

    rows = {}
    include_references = !params['include_references'].nil?
    only_with_data = !params['only_rows_with_data'].nil?

    # At this point, we'll have a list of the most specific taxa requested at each level
    @lowest_requested_taxa.each do |taxon|
      # Need to build a matrix of OTU x TRAIT x VALUE x NOTE
      # Start with an array of Otu IDs, ordered by OTU Id
      otu_ids = taxon.otus.pluck(:otu_id)
      # Create a hash populated with Otu IDs.  Sparse
      rows.merge!(Hash[otu_ids.map {|v| [v, nil]}])
      # Could split this out to loop over the predicates
      ContinuousTraitValue.where(:otu_id => otu_ids).where(:continuous_trait_id => @continuous_trait_predicate_map.keys).includes(:otu => [:continuous_trait_notes]).includes(:continuous_trait, :source_reference).each do |continuous_trait_value|
        trait_id = continuous_trait_value.continuous_trait_id
        value_id = continuous_trait_value.id
        # loops over the continuous_trait_value

        # Insert a value for this OTU in the rows hash if it's empty
        # Lots of building empty hashes/arrays the first time through
        # would be good to abstract this out
        result_row = rows[continuous_trait_value.otu_id] ||= {}
        result_hash = result_row[:continuous] ||= {}
        # matches will be used to indicate whether or not the criteria was met
        # There may be more than one trait value, and each could have a source and notes
        result_arrays = result_hash[trait_id] ||= {
          :values => [], #
          :sources => [], # Array of strings of sources
          :notes => nil, # Array of notes attached to a categorical trait value.
          :value_matches => {} # Hash of categorical_trait_value_id => true|false
        }
        result_arrays[:values] << { value_id => continuous_trait_value.formatted_value }
        result_arrays[:sources] << { value_id => continuous_trait_value.source_reference.to_s } if include_references
        # Notes are optional and only stored once per OTUxTrait
        # When a note is found, we record the trait_id so that the view can display a notes column for the trait
        # Notes are expected to be rare, so we only display the column if we have data
        note = continuous_trait_value.otu.continuous_trait_notes.find{|n| n.continuous_trait.id == trait_id }
        if note
          continuous_trait_notes_ids << trait_id
          result_arrays[:notes] ||= note.notes
        end

        predicate = @continuous_trait_predicate_map[trait_id]
        # Record a match if no predicate or if the predicate was matched
        # Note that the database will not be queried again unless there is a predicate
        if predicate.length == 0 || ContinuousTraitValue.where(:id => value_id).where(predicate).count > 0
          result_arrays[:value_matches][value_id] = true
        else
          result_arrays[:value_matches][value_id] = false
        end
      end
      CategoricalTraitValue.where(:otu_id => otu_ids).where(:categorical_trait_id => @categorical_trait_category_map.keys).includes(:otu => [:categorical_trait_notes]).includes(:categorical_trait, :categorical_trait_category, :source_reference).each do |categorical_trait_value|
        trait_id = categorical_trait_value.categorical_trait_id
        value_id = categorical_trait_value.id
        # loops over the categorical_trait_value

        # Insert a value for this OTU in the rows hash if it's empty
        # Lots of building empty hashes/arrays the first time through
        # would be good to abstract this out
        result_row = rows[categorical_trait_value.otu_id] ||= {}
        result_hash = result_row[:categorical] ||= {}
        # matches will be used to indicate whether or not the criteria was met
        # There may be more than one trait value, and each could have a source and notes
        result_arrays = result_hash[trait_id] ||= {
          :values => [], #
          :sources => [], # Array of strings of sources
          :notes => nil, # Array of notes attached to a categorical trait value.
          :value_matches => {} # Hash of categorical_trait_value_id => true|false
        }
        result_arrays[:values] << { value_id => categorical_trait_value.formatted_value }
        result_arrays[:sources] << { value_id => categorical_trait_value.source_reference.to_s } if include_references
        # Notes are optional and only stored once per OTUxTrait
        # When a note is found, we record the trait_id so that the view can display a notes column for the trait
        # Notes are expected to be rare, so we only display the column if we have data
        note = categorical_trait_value.otu.categorical_trait_notes.find{|n| n.continuous_trait.id == trait_id }
        if note
          categorical_trait_notes_ids << trait_id
          result_arrays[:notes] ||= note.notes
        end

        category_ids = @categorical_trait_category_map[trait_id]
        # Record a match if no predicate or if the predicate was matched
        # Note that the database will not be queried again unless there is a predicate
        if category_ids.length == 0 || CategoricalTraitValue.where(:id => value_id, :categorical_trait_category_id => category_ids)
          # No category id specified or value matched input criteria
          result_arrays[:value_matches][value_id] = true
        else
          result_arrays[:value_matches][value_id] = false
        end
      end
    end # taxon

    # Filter the rows hash: Remove empty rows and rows that should be left out due to filtering options
    rows.reject!{|otu_id, row_hash| row_hash.nil? || !include_in_results?(row_hash, @trait_operator, only_with_data)}
    # and another hash of otu names to otu ids
    # Get the name for each OTU in the rows hash and stuff it back into the hash
    #
    Otu.where(:id => rows.keys).includes(:otu_metadata_values => [:otu_metadata_field]).each do |otu|
      rows[otu.id][:sort_name] = otu.sort_name
      rows[otu.id][:name] = otu.name
      rows[otu.id][:metadata] = otu.metadata_hash
      otu.metadata_hash.keys.each{|field_name| otu_metadata_field_names << field_name unless field_name.in? otu_metadata_field_names}
    end
    # When sorting a hash, it is converted to an array where element 0 is the key and element 1 is the value
    # sort based on the :sort_name in the value and convert back to a hash
    rows = Hash[rows.sort{|a,b| a[1][:sort_name] <=> b[1][:sort_name]}]

    @results[:columns][:categorical_trait_notes_ids] = categorical_trait_notes_ids
    @results[:columns][:continuous_trait_notes_ids] = continuous_trait_notes_ids
    @results[:columns][:otu_metadata_field_names] = otu_metadata_field_names

    # data to return to view
    # @results[:columns] is a hash with keys :categorical_traits and :continuous_traits
    @results[:rows] = rows # rows is an array of hashes.  Each hash has :otu, :categorical_trait_values, and :continuous_trait_values
    @results[:include_references] = include_references

    respond_to do |format|
      format.csv do
        filename = "results-#{Time.now.strftime("%Y%m%d")}.csv"
        if request.env['HTTP_USER_AGENT'] =~ /msie/i
          headers['Pragma'] = 'public'
          headers["Content-type"] = "text/plain"
          headers['Cache-Control'] = 'no-cache, must-revalidate, post-check=0, pre-check=0'
          headers['Content-Disposition'] = "attachment; filename=\"#{filename}\""
          headers['Expires'] = "0"
        else
          headers["Content-Type"] ||= 'text/csv'
          headers["Content-Disposition"] = "attachment; filename=\"#{filename}\""
        end
      end
      format.html
    end
  end

  def show_trait_list
    @categorical_traits = @project.categorical_traits.sorted
    @continuous_traits = @project.continuous_traits.sorted
  end

  private

  # Used to filter OTUs based on AND/OR criteria
  def include_in_results?(row_hash, operator, only_with_data)
    if operator == :and
      # AND: include if
      # continuous: all values in :value_matches are true and
      # categorical: all values in value_matches are true
      def all_match(row_hash, type)
        return false if row_hash[type].nil?
        row_hash[type].values.map{|x| x[:value_matches]}.all{|x| true.in? x.values}
      end
      return all_match(row_hash, :categorical) && all_match(row_hash, :continuous)
    else
      # assume :or
      def any_match(row_hash, type)
        return false if row_hash[type].nil?
        row_hash[type].values.map{|x| x[:value_matches]}.any?{|x| true.in? x.values}
      end
      def none_coded(row_hash, type)
        return true if row_hash[type].nil?
        row_hash[type].values.all?{|x| x[:value_matches].size == 0}
      end
      # OR: include if
      # continuous: any value in :value_matches is true
      # or categorical: any value in :value_matches is true
      return true if any_match(row_hash, :categorical) || any_match(row_hash, :continuous)
      # or (only_with_data == false AND :value_matches is empty for both
      return true if !only_with_data && none_coded(row_hash, :categorical) && none_coded(row_hash, :continuous)
      return false
    end
  end

  # Extracts the taxon ids and the lowest requested taxa from the taxonomy portion of the search form
  def analyze_lowest_requested_taxa
    # The requested taxon filters have parameter names that correspond to IcznGroup names.
    # The values are the Taxon IDs
    sorted_groups_requested = @project.iczn_groups.sorted.where(:name => params.keys)
    valid_group_names = @project.iczn_groups.sorted.pluck(:name)
    @results[:columns][:iczn_groups]= sorted_groups_requested.map{|group| {:name => group.name, :id => group.id}}

    # An example params hash looks like this
    # "{"htg"=>{"0"=>"2601", "2"=>"2601"}, "order"=>{"0"=>"2602", "2"=>"2602"}, "family"=>{"0"=>"2603", "2"=>"2607"}, "genus"=>{"0"=>"2625", "2"=>"2612"}, "species"=>{"0"=>"2623", "2"=>"2613"}, "trait_types"=>{"0"=>""}, "categorical_trait_name"=>{"0"=>""}, "categorical_trait_values"=>{"0"=>""}, "continuous_trait_name"=>{"0"=>""}, "continuous_trait_value_predicates"=>{"0"=>""}, "continuous_trait_entries"=>{"0"=>""}, "include_references"=>"on", "controller"=>"search", "action"=>"results"}"

    indices = []

    params.each do |pk, pv|
      next unless valid_group_names.include? pk
      # pk is one of 'htg','order',etc...
      # pv looks like {"0"=>"2602", "2"=>"2607"}
      # "0" and "2" are integers in string format, and these indices may not be consecutive
      indices += pv.keys.map{|n| n.to_i}
    end
    indices.sort!.uniq!

    @lowest_requested_taxa = []
    @selected_taxon_ids = []

    indices.each do |index|
      lowest_requested_taxon = nil
      sorted_groups_requested.each do |group|
        taxon_id_str = params[group.name][index.to_s]
        unless taxon_id_str.nil? || taxon_id_str.empty?
          @selected_taxon_ids << taxon_id_str.to_i
          lowest_requested_taxon = @project.taxa.find(taxon_id_str.to_i)
        end
      end
      @lowest_requested_taxa << lowest_requested_taxon if lowest_requested_taxon
    end
  end

  # extracting functionality out of search to deliver a list of traits
  def assemble_trait_filters
    @continuous_trait_predicate_map = {} # map of continuous_trait_ids to arrays of predicates and values
    @categorical_trait_category_map = {} # Map of categorical_trait_ids to arrays of categorical_trait_category_ids
    # if All traits specified, find them all!
    if params['select_all_traits'] # Checkbox, only exists in params if checked
      # Need the selected taxon_ids
      # First get all the traits from the selected taxonomy
      continuous_traits, categorical_traits,   = [],[]
      @project.taxa.where(:id => @selected_taxon_ids).each do |taxon|
        continuous_traits = continuous_traits | taxon.grouped_continuous_traits
        categorical_traits = categorical_traits | taxon.grouped_categorical_traits
      end
      # selecting all traits - do not apply predicates or values
      continuous_traits.each{|trait| @continuous_trait_predicate_map[trait.id] = [] }
      categorical_traits.each{|trait| @categorical_trait_category_map[trait.id] = []}
      # done
    else
      # select all was not checked, create filters based on form selections
      continuous_trait_filters = {}
      # Continuous Trait Values
      continuous_trait_indices = params['trait_type'].select{|k,v| v == 'continuous'}.keys
      unless continuous_trait_indices.empty?
        params['trait_name'].select{|k,v| k.in?(continuous_trait_indices)}.reject{|k,v| v.empty?}.each do |k,v|
          trait_id = Integer(v)
          # This block is invoked for each filter on the search form
          # Multiple filters may reference the same trait, so keep the values/predicates for each trait together
          if continuous_trait_filters[trait_id].nil?
            continuous_trait_filters[trait_id] = {:predicates => [], :values => []}
          end
          predicates = continuous_trait_filters[trait_id][:predicates]
          values = continuous_trait_filters[trait_id][:values]

          # Check for the equals/less than/etc
          # get the predicate for this row
          if params['trait_values'][k] && params['trait_entries'][k]
            unless params['trait_entries'][k].blank?
              field_value = Float(params['trait_entries'][k])
              case params['trait_values'][k]
                when 'gt'
                  predicates << 'value > ?'
                  values << field_value
                when 'lt'
                  predicates << 'value < ?'
                  values << field_value
                when 'eq'
                  predicates << 'value = ?'
                  values << field_value
                when 'ne'
                  predicates << 'value != ?'
                  values << field_value
              end
            end
          end
          continuous_trait_filters[trait_id][:predicates] = predicates
          continuous_trait_filters[trait_id][:values] = values
        end
      end

      # Convert to one predicate, and use the operator
      # The argument to a where() call should look like this: where(['value > ? AND value < ?', 1, 2])
      # joining the predicates provides the 'value > ? AND value < ?'
      # The * in front of the values array converts it to varargs
      continuous_trait_filters.each do |trait_id, filter|
        @continuous_trait_predicate_map[trait_id] = [filter[:predicates].join(" #{@trait_operator} "), *filter[:values]]
      end

      # Categorical Trait Values
      categorical_trait_indices = params['trait_type'].select{|k,v| v == 'categorical'}.keys
      unless categorical_trait_indices.empty?
        params['trait_name'].select{|k,v| k.in?(categorical_trait_indices)}.reject{|k,v| v.empty?}.each do |k,v|
          trait_id = Integer(v)
          trait_category_ids = @categorical_trait_category_map[trait_id] || []

          if params['trait_values'][k]
            unless params['trait_values'][k].blank?
              trait_category_ids << Integer(params['trait_values'][k])
            end
          end
          @categorical_trait_category_map[trait_id] = trait_category_ids
        end
      end
    end
  end

  def taxa_in_iczn_group_with_parents(iczn_group_id, parent_taxon_ids)
    iczn_group = @project.iczn_groups.find(iczn_group_id)
    taxon_ids = @project.taxa.where(:id => parent_taxon_ids).map{|t| t.descendants_with_level(iczn_group).map{|x| x.id}}.inject{|memo,id| memo & id}
    return @project.taxa.where(:id => taxon_ids).sorted
  end

  def traits
    return @project.categorical_traits.sorted
  end

  def categorical_trait_values_for_trait(trait_id)
    if trait_id
      trait = @project.categorical_traits.find(trait_id)
      return trait.categorical_trait_categories
    end
  end
end
