class CategoricalTraitsController < ApplicationController
  before_filter :set_project
  def index
    where_options = {}
    if params[:otu]
      where_options[:otu_id] = params[:otu].to_i
    end
    if params[:start]
      @start = params[:start].to_i
    else
      @start = 0
    end
    if params[:count]
      @count = params[:count].to_i
    else
      @count = 20
    end
    @total = @project.categorical_traits.where(where_options).count
    @categorical_traits = @project.categorical_traits.where(where_options).sorted.limit(@count).offset(@start)

  end

  def show
    @categorical_trait = @project.categorical_traits.find(params[:id])
  end

  def edit
    @categorical_trait = @project.categorical_traits.find(params[:id])
  end

  def update
    @categorical_trait = @project.categorical_traits.find(params[:id])
    if @categorical_trait.update_attributes(params[:categorical_trait])
      flash[:notice] = 'Trait updated successfully'
      redirect_to(:action => 'show', :id => @categorical_trait.id)
    else
      render('edit')
    end
  end

end
