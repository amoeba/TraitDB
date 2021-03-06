class Project < ActiveRecord::Base
  attr_accessible :name, :summary_description, :detail_description, :url, :url_text
  validates_presence_of :name
  validates_uniqueness_of :name
  has_and_belongs_to_many :users

  has_many :categorical_traits, :dependent => :destroy
  has_many :continuous_traits, :dependent => :destroy
  has_many :csv_datasets, :dependent => :destroy
  has_many :csv_import_configs, :dependent => :destroy
  has_and_belongs_to_many :iczn_groups # will be important for building search form - to know what groups are in use
  has_many :otus, :dependent => :destroy
  has_many :otu_metadata_fields, :dependent => :destroy
  has_many :taxa, :dependent => :destroy
  has_many :trait_groups, :dependent => :destroy
  has_many :trait_sets, :dependent => :destroy
  has_many :source_references, :dependent => :destroy

  scope :sorted, -> { order('name ASC') }

  def add_iczn_groups(groups)
    groups.each do |iczn_group|
      iczn_groups << iczn_group unless iczn_group.in? iczn_groups
    end
    save
  end

  def clear_all_data!
    categorical_traits.destroy_all
    continuous_traits.destroy_all
    csv_datasets.destroy_all
    csv_import_configs.destroy_all
    iczn_groups.destroy_all
    otus.destroy_all
    otu_metadata_fields.destroy_all
    taxa.destroy_all
    trait_groups.destroy_all
    trait_sets.destroy_all
    source_references.destroy_all
  end

end
