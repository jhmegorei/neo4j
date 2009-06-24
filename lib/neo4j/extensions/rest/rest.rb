module Neo4j

  module Rest #:nodoc: all
    # contains a list of rest node class resources
    REST_NODE_CLASSES = {}


    def self.base_uri
      host = Sinatra::Application.host
      port = Sinatra::Application.port
      "http://#{host}:#{port}"
    end

    def self.load_class(clazz)
      clazz = clazz.split("::").inject(Kernel) do |container, name|
        container.const_get(name.to_s)
      end
    end

    # -------------------------------------------------------------------------
    # /neo
    # -------------------------------------------------------------------------

    Sinatra::Application.post("/neo") do
      body = request.body.read
      Object.class_eval body
      200
    end


    Sinatra::Application.get("/neo") do
      if request.accept.include?("text/html")
        html = "<html><body><h2>Neo4j.rb v #{Neo4j::VERSION} is alive !</h2><p/><h3>Defined REST classes</h3>"
        REST_NODE_CLASSES.keys.each {|clazz| html << "Class '" + clazz + "' <br/>"}
        html << "</body></html>"
        html
      else
        content_type :json
        {:classes => REST_NODE_CLASSES.keys, :ref_node => Neo4j.ref_node._uri}.to_json
      end
    end


    # -------------------------------------------------------------------------
    # /relationships/<id>
    # -------------------------------------------------------------------------

    Sinatra::Application.get("/relationships/:id") do
      content_type :json
      Neo4j::Transaction.run do
        rel = Neo4j.load_relationship(params[:id].to_i)
        return 404, "Can't find relationship with id #{params[:id]}" if rel.nil?
        # include hyperlink to end_node if that has an _uri method
        end_node_hash = {:uri => rel.end_node._uri}

        # include hyperlink to start_node if that has an _uri method
        start_node_hash = {:uri => rel.start_node._uri}

        {:properties => rel.props, :start_node => start_node_hash, :end_node => end_node_hash}.to_json
      end
    end


    # -------------------------------------------------------------------------
    # /nodes/<classname>
    # -------------------------------------------------------------------------

    # Allows searching for nodes (provided that they are indexed). Supports the following:
    # <code>/nodes/classname?search=name:hello~</code>:: Lucene query string
    # <code>/nodes/classname?name=hello</code>:: Exact match on property
    # <code>/nodes/classname?sort=name,desc</code>:: Specify sorting order
    Sinatra::Application.get("/nodes/:class") do
      content_type :json
      clazz = Neo4j::Rest.load_class(params[:class])
      return 404, "Can't find class '#{classname}'" if clazz.nil?

      # remote param that are part of the path and not a query parameter
      query = nil
      unless (params.nil?)
        query = params.clone
        query.delete('class')
      end

      Neo4j::Transaction.run do
        resources = clazz.find(query) # uses overridden find method -- see below
        resources.map{|res| res.props}.to_json
      end
    end

    Sinatra::Application.post("/nodes/:class") do
      content_type :json

      clazz = Neo4j::Rest.load_class(params[:class])
      return 404, "Can't find class '#{classname}'" if clazz.nil?

      uri = Neo4j::Transaction.run do
        node = clazz.new
        data = JSON.parse(request.body.read)
        properties = data['properties']
        node.update(properties)
        node._uri
      end
      redirect "#{uri}", 201 # created
    end


    # -------------------------------------------------------------------------
    # /nodes/<classname>/<id>
    # -------------------------------------------------------------------------

    Sinatra::Application.get("/nodes/:class/:id") do
      content_type :json

      Neo4j::Transaction.run do
        node = Neo4j.load(params[:id])
        return 404, "Can't find node with id #{params[:id]}" if node.nil?
        relationships = node.relationships.outgoing.inject({}) do |hash, v|
          type = v.relationship_type.to_s
          hash[type] ||= []
          hash[type] << "#{Neo4j::Rest.base_uri}/relationships/#{v.neo_relationship_id}"
          hash
        end
        {:relationships => relationships, :properties => node.props}.to_json
      end
    end

    Sinatra::Application.put("/nodes/:class/:id") do
      content_type :json
      Neo4j::Transaction.run do
        body = request.body.read
        data = JSON.parse(body)
        properties = data['properties']
        node = Neo4j.load(params[:id])
        node.update(properties, true)
        node.props.to_json
      end
    end

    Sinatra::Application.delete("/nodes/:class/:id") do
      content_type :json
      Neo4j::Transaction.run do
        node = Neo4j.load(params[:id])
        return 404, "Can't find node with id #{params[:id]}" if node.nil?
        node.delete
        ""
      end
    end


    # -------------------------------------------------------------------------
    # /nodes/<classname>/<id>/<property>
    # -------------------------------------------------------------------------

    Sinatra::Application.get("/nodes/:class/:id/traverse") do
      content_type :json
      Neo4j::Transaction.run do
        node = Neo4j.load(params[:id])
        return 404, "Can't find node with id #{params[:id]}" if node.nil?

        relationship = params['relationship']
        depth = params['depth']
        depth ||= 1
        uris = node.traverse.outgoing(relationship.to_sym).depth(depth.to_i).collect{|node| node._uri}
        {'uri_list' => uris}.to_json
      end
    end


    Sinatra::Application.get("/nodes/:class/:id/:prop") do
      content_type :json
      Neo4j::Transaction.run do
        node = Neo4j.load(params[:id])
        return 404, "Can't find node with id #{params[:id]}" if node.nil?
        prop = params[:prop].to_sym
        if node.class.relationships_info.keys.include?(prop)      # TODO looks weird, why this complicated
          rels = node.send(prop) || []
          rels.map{|rel| rel.props}.to_json
        else
          {prop => node.get_property(prop)}.to_json
        end
      end
    end


    Sinatra::Application.put("/nodes/:class/:id/:prop") do
      content_type :json
      Neo4j::Transaction.run do
        node = Neo4j.load(params[:id])
        property = params[:prop]
        body = request.body.read
        data = JSON.parse(body)
        value = data[property]
        return 409, "Can't set property #{property} with JSON data '#{body}'" if value.nil?
        node.set_property(property, value)
        200
      end
    end


    URL_REGEXP = Regexp.new '((http[s]?|ftp):\/)?\/?([^:\/\s]+)((\/\w+)*\/)([\w\-\.]+[^#?\s]+)$' #:nodoc:

    Sinatra::Application.post("/nodes/:class/:id/:rel") do
      content_type :json
      new_id = Neo4j::Transaction.run do
        node = Neo4j.load(params[:id])
        return 404, "Can't find node with id #{params[:id]}" if node.nil?
        rel = params[:rel]

        body = request.body.read
        data = JSON.parse(body)
        uri = data['uri']
        match = URL_REGEXP.match(uri)
        return 400, "Bad node uri '#{uri}'" if match.nil?
        to_clazz, to_node_id = match[6].split('/')

        other_node = Neo4j.load(to_node_id.to_i)
        return 400, "Unknown other node with id '#{to_node_id}'" if other_node.nil?

        if to_clazz != other_node.class.to_s
          return 400, "Wrong type id '#{to_node_id}' expected '#{to_clazz}' got '#{other_node.class.to_s}'"
        end

        rel_obj = node.relationships.outgoing(rel) << other_node # node.send(rel).new(other_node)

        return 400, "Can't create relationship to #{to_clazz}" if rel_obj.nil?

        rel_obj.neo_relationship_id
      end
      redirect "/relationships/#{new_id}", 201 # created
    end
  end





end