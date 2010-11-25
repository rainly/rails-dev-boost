module RailsDevelopmentBoost
  module DependenciesPatch
    def self.apply!
      # retain the original method in case the application overwrites it on its modules/klasses
      Module.send :alias_method, :_mod_name, :name
      
      patch = self
      ActiveSupport::Dependencies.module_eval do
        remove_possible_method :remove_unloadable_constants!
        remove_possible_method :clear
        include patch
        alias_method_chain :load_file, 'constant_tracking'
        alias_method_chain :remove_constant, 'handling_of_connections'
        extend patch
      end
    end
    
    mattr_accessor :module_cache
    self.module_cache = []
    
    mattr_accessor :file_map
    self.file_map = {}
    
    mattr_accessor :constants_being_removed
    self.constants_being_removed = []
    
    mattr_accessor :explicit_dependencies
    self.explicit_dependencies = {}
    
    def unload_modified_files!
      log_call
      file_map.values.each do |file|
        file.constants.dup.each { |const| remove_constant(const) } if file.changed?
      end
    end
    
    def remove_explicitely_unloadable_constants!
      explicitly_unloadable_constants.each { |const| remove_constant(const) }
    end
    
    # Overridden.
    def clear
    end
    
    # Augmented `load_file'.
    def load_file_with_constant_tracking(path, *args, &block)
      result = load_file_without_constant_tracking(path, *args, &block)
      new_constants = autoloaded_constants - file_map.values.map(&:constants).flatten
      
      # Associate newly loaded constants to the file just loaded
      associate_constants_to_file(new_constants, path) if new_constants.any?

      return result
    end
    
    def associate_constants_to_file(constants, file_path)
      path_marked_loaded = file_path.sub(/\.rb$/, '')
      (file_map[path_marked_loaded] ||= LoadedFile.new(file_path)).add_constants(constants)
    end
    
    # Augmented `remove_constant'.
    def remove_constant_with_handling_of_connections(const_name)
      fetch_module_cache do
        prevent_further_removal_of(const_name) do
          if qualified_const_defined?(const_name) && object = const_name.constantize
            handle_connected_constants(object, const_name)
            remove_same_file_constants(const_name)
            remove_parent_modules_if_autoloaded(object) if object.kind_of?(Module)
          end
          result = remove_constant_without_handling_of_connections(const_name)
          clear_tracks_of_removed_const(const_name, object)
          return result
        end
      end
    end
    
    def add_explicit_dependency(parent, child)
      (explicit_dependencies[parent.to_s] ||= []) << child.to_s
    end
    
  private
    
    def handle_connected_constants(object, const_name)
      return unless Module === object && qualified_const_defined?(const_name)
      remove_explicit_dependencies_of(const_name)
      remove_dependent_modules(object)
      update_activerecord_related_references(object)
      autoloaded_constants.grep(/^#{const_name}::[^:]+$/).each { |const| remove_constant(const) }
    end
    
    def autoloaded_namespace_object?(object) # faster than going through Dependencies.autoloaded?
      LoadedFile.constants_to_files[object._mod_name]
    end
    
    # AS::Dependencies doesn't track same-file nested constants, so we need to look out for them on our own.
    # For example having loaded an abc.rb that looks like this:
    #   class Abc; class Inner; end; end
    # AS::Dependencies would only add "Abc" constant name to its autoloaded_constants list, completely ignoring Abc::Inner. This in turn
    # can cause problems for classes inheriting from Abc::Inner somewhere else in the app.
    def remove_parent_modules_if_autoloaded(object)
      unless autoloaded_namespace_object?(object)
        while (object = object.parent) != Object
          if autoloaded_namespace_object?(object)
            remove_constant(object._mod_name)
            break
          end
        end
      end
    end    
    
    def remove_same_file_constants(const_name)
      if same_file_constants = LoadedFile.other_constants_from_the_same_files_as(const_name)
        same_file_constants.each {|const_name| remove_constant(const_name)}
      end
    end
    
    def remove_explicit_dependencies_of(const_name)
      explicit_dependencies.delete(const_name).uniq.each {|depending_const| remove_constant(depending_const)} if explicit_dependencies[const_name]
    end
    
    def clear_tracks_of_removed_const(const_name, object)
      autoloaded_constants.delete(const_name)
      module_cache.delete_if { |mod| mod._mod_name == const_name }
      clean_up_references(const_name, object)
      file_map.dup.each do |path, file|
        file.delete_constant(const_name)
        if file.constants.empty?
          loaded.delete(path)
          file_map.delete(path)
        end
      end
    end
    
    def clean_up_references(const_name, object)
      references[const_name].try(:loose)
      ActiveSupport::DescendantsTracker.delete(object)
    end
    
    def remove_dependent_modules(mod)
      fetch_module_cache do |modules|
        modules.dup.each do |other|
          next unless other < mod || other.singleton_class.ancestors.include?(mod)
          next unless other.superclass == mod if Class === mod
          next unless qualified_const_defined?(other._mod_name) && other._mod_name.constantize == other
          remove_constant(other._mod_name)
        end
      end
    end
    
    # egrep -ohR '@\w*([ck]lass|refl|target|own)\w*' activerecord | sort | uniq
    def update_activerecord_related_references(klass)
      return unless defined?(ActiveRecord)
      return unless klass < ActiveRecord::Base

      # Reset references held by macro reflections (klass is lazy loaded, so
      # setting its cache to nil will force the name to be resolved again).
      ActiveRecord::Base.descendants.each do |model|
        model.reflections.each_value do |reflection|
          reflection.instance_eval do
            @klass = nil if @klass == klass
          end
        end
      end
    end
  
  private

    def fetch_module_cache
      return(yield(module_cache)) if module_cache.any?
      
      ObjectSpace.each_object(Module) { |mod| module_cache << mod unless (mod._mod_name || "").empty? }
      begin
        yield module_cache
      ensure
        module_cache.clear
      end
    end

    def prevent_further_removal_of(const_name)
      return if constants_being_removed.include?(const_name)
      
      constants_being_removed << const_name
      begin
        yield
      ensure
        constants_being_removed.delete(const_name)
      end
    end
  end
end
