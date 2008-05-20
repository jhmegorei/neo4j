module Neo
  class Node
    attr_reader :internal_node 
    
    def initialize(*args)
      if args.length == 1 and args[0].kind_of?(org.neo4j.api.core.Node)
        @internal_node = args[0]
        # TODO check if a transaction is needed, what happends if we already are in a transaction ?
        #puts "Create new for #{self.class.to_s}: #{@internal_node.hasProperty('classname')}"
        Neo.transaction {self.classname = self.class.to_s} unless @internal_node.hasProperty("classname")
        #puts "DONE"
      elsif block_given? # check if we should run in a transaction
        Neo.transaction { init_internal; yield self }
      else
        init_internal
      end
    end
    
    def init_internal
      @internal_node = Neo::create_node  
      self.classname = self.class.to_s
      # TODO set classname node to point to self
    end

    def method_missing(methodname, *args)
      # allows to set and get any neo property without declaring them first
      name = methodname.to_s
      setter = /=$/ === name
      expected_args = 0
      if setter
        name = name[0...-1]
        expected_args = 1
      end
      unless args.size == expected_args
        err = "method '#{name}' has wrong number of arguments (#{args.size} for #{expected_args})"
        raise ArgumentError.new(err)
      end

      if setter
          @internal_node.set_property(name, args[0])
      else
          return @internal_node.get_property(name)
      end      
    end
    
    def self.inherited(c)
      # This method adds a MetaNode for each class that inherits from the Node
      # must avoid endless recursion 
      if c == Neo::MetaNode or c == Neo::MetaNodes
        return
      end
      
      # create a meta node representing the new class
      # TODO check: should only be created once  ?      
      metanode = MetaNode.new do |n|
       n.meta_classname = c.to_s
       Neo::meta_nodes.nodes << n
      end
      
      # define the 'meta_node' method in the new class
      classname = class << c;  self;  end
      classname.send :define_method, :meta_node do
        metanode
      end      

    end
    
    # 
    # Returns a unique id
    # Calls getId on the neo node java object
    #
    def neo_node_id
      @internal_node.getId()
    end
    
    #
    # Allows to declare Neo properties.
    # Notice that you do not need to declare any properties in order to 
    # set and get a neo property.
    # An undeclared setter/getter will handled in the method_missing method instead.
    #
    def self.properties(*props)
      props.each do |prop|
        define_method(prop) do 
          @internal_node.get_property(prop.to_s)
        end

        name = (prop.to_s() +"=")
        define_method(name) do |value|
          @internal_node.set_property(prop.to_s, value)
        end
      end
    end
    
    
    #
    # Allows to declare Neo relationsships.
    # The speficied name will be used as the type of the neo relationship.
    #
    def self.add_relation_type(type)
        define_method(type) do 
          Relations.new(self,type.to_s)
        end
    end
    
    
    def self.relations(*relations)
      relations.each {|type| add_relation_type(type)}
    end

    properties :classname
  end
end