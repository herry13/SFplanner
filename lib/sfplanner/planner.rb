require 'fileutils'
require 'thread'

module Sfp
	class Planner
		Heuristic = 'mixed' # lmcut, cg, cea, ff, mixed ([cg|cea|ff]=>lmcut)
		Debug = (ENV['SFPLANNER_DEBUG'] ? true : false)
		TranslatorBenchmarkFile = 'sas_translator.benchmarks'

		class Config
			# The timeout for the solver in seconds (default 60s/1mins)
			@@timeout = 60

			def self.timeout; @@timeout; end

			def self.set_timeout(timeout); @@timeout = timeout; end

			# The maximum memory that can be consumed by the solver
			@@max_memory = 2048000 # (in K) -- default ~2GB

			def self.max_memory; @@max_memory; end

			def self.set_max_memory(memory); @@max_memory = memory; end
		end


		attr_accessor :debug
		attr_reader :parser

		# @param all parameters are passed to Sfp::Parser#initialize method
		#
		def initialize(params={})
			@parser = Sfp::Parser.new(params)
			@debug = Debug
		end

		# @param :string      => SFP task in string
		#        :sfp         => SFP task in Hash data structure
		#        :file        => SFP task in file with specified path
		#        :json_input  => SFP task in JSON format
		#        :sas_plan    => if true then return a raw SAS plan
		#        :parallel    => if true then return a parallel (partial-order) plan,
		#                        if false or nil then return a sequential plan
		#        :json        => if true then return the plan in JSON
		#        :pretty_json => if true then return in pretty JSON
		#        :bsig        => if true then return the solution plan as a BSig model
		#
		# @return if solution plan is found then returns a JSON or Hash
		#         otherwise return nil
		#
		def solve(params={})
			if params[:string].is_a?(String)
				@parser.parse(string)
			elsif params[:sfp].is_a?(Hash)
				@parser.root = params[:sfp]
			elsif params[:file].is_a?(String)
				raise Exception, "File not found: #{params[:file]}" if not File.exist?(params[:file])
				if params[:json_input]
					@parser.root = json_to_sfp(JSON[File.read(params[:file])])
				else
					@parser.home_dir = File.expand_path(File.dirname(params[:file]))
					@parser.parse(File.read(params[:file]))
				end
			end

			@debug = true if params[:debug]

			save_sfp_task if @debug

			if not @parser.conformant
				return self.solve_classical_task(params)
			else
				return self.solve_conformant_task(params)
			end
		end

		# Return Behavioural Signature (BSig) model of previously generated plan.
		# 
		# @param :parallel    => if true then return a parallel (partial-order) plan,
		#                        if false or nil then return a sequential plan
		#        :json        => if true then return the plan in JSON
		#        :pretty_json => if true then return in pretty JSON
		#
		# @return if solution BSig model is found then returns a JSON or Hash,
		#         otherwise return nil
		#
		def to_bsig(params={})
			raise Exception, "Conformant task is not supported yet" if @parser.conformant

			bsig = (params[:parallel] ? self.to_parallel_bsig : self.to_sequential_bsig)

			return (params[:json] ? JSON.generate(bsig) :
			        (params[:pretty_json] ? JSON.pretty_generate(bsig) : bsig))
		end

		# Return the final state if the plan is executed.
		# 
		# @param :json        => if true then return in JSON
		#        :pretty_json => if true then return in pretty JSON
		#
		# @return [Hash]
		#
		def final_state(params={})
			return nil if @plan.nil?
			state = @sas_task.final_state
			return (params[:json] ? JSON.generate(state) :
			        (params[:pretty_json] ? JSON.pretty_generate(state) : state))
		end

		protected
		def to_dot(plan)
			if plan['type'] == 'parallel'
				Sfp::Graph.partial2dot(self.get_parallel_plan)
			else
				Sfp::Graph.sequential2dot(self.get_sequential_plan)
			end
		end

		def json_to_sfp(json)
			json.accept(Sfp::Visitor::SfpGenerator.new(json))
			json.each do |key,val|
				next if key[0,1] == '_'
				if val.is_a?(Hash) and val['_context'] == 'state'
					#val.each { |k,v| v.delete('_parent') if k[0,1] != '_' and v.is_a?(Hash) and v.has_key?('_parent') }
				end
			end
		end

		def save_sfp_task
			sfp_task = Sfp::Helper.deep_clone(@parser.root)
			sfp_task.accept(Sfp::Visitor::ParentEliminator.new)
			File.open('/tmp/planning.json', 'w') { |f| f.write(JSON.pretty_generate(sfp_task)) }
		end

		def solve_conformant_task(params={})
			raise Exception, "Conformant task is not supported yet" if params[:bsig]

			# 1) generate all possible initial states
			#    remove states that do not satisfy the global constraint
			def get_possible_partial_initial_states(init)
				def combinators(variables, var_values, index=0, result={}, bucket=[])
					if index >= variables.length
						# collect
						bucket << result.clone
					else
						var = variables[index]
						var_values[var].each do |value|
							result[var] = value
							combinators(variables, var_values, index+1, result, bucket)
						end
					end
					bucket
				end
				# collect variables with non-deterministic value
				collector = Sfp::Visitor::ConformantVariables.new
				init.accept(collector)
				vars = collector.var_values.keys
				combinators(vars, collector.var_values)
			end

			# 2) for each initial states, generate a plan (if possible)
			#    for given goal state
			def get_possible_plans(partial_inits)
				# TODO
				solutions = []
				partial_inits.each do |partial_init|
					parser = Sfp::Parser.new
					parser.root = Sfp::Helper.deep_clone(@parser.root)
					init = parser.root['initial']
					partial_init.each do |path,value|
						parent, var = path.extract
						parent = init.at?(parent)
						parent[var] = value
					end
					plan, sas_task = self.solve_sas(parser)
					solution = {:partial_init => partial_init,
					            :plan => plan,
					            :sas_task => sas_task}
					solutions << solution
				end
				solutions
			end

			# 3) merge the plans into one
			def merge_plans(solutions)
				# TODO
				solutions.each { |sol| puts sol[:partial_init].inspect + " => " + sol[:plan].inspect }
				nil
			end

			partial_inits = get_possible_partial_initial_states(@parser.root['initial'])
			solutions = get_possible_plans(partial_inits)
			merged_plan = merge_plans(solutions)
		end

		def solve_classical_task(params={})
			benchmarks = {}
			benchmarks[:solve_sas] = Benchmark.realtime {
				@plan, @sas_task = self.solve_sas(@parser, params)
			}

			return @plan if params[:sas_plan]

			return to_bsig(params) if params[:bsig]

			plan = nil
			benchmarks[:get_parallel_plan] = Benchmark.realtime {
				plan = (params[:parallel] ? self.get_parallel_plan : self.get_sequential_plan)
			}

			output = nil

			benchmarks[:to_json] = Benchmark.realtime {
				if params[:dot]
					output = to_dot(plan)
				elsif params[:json]
					output = JSON.generate(plan)
				elsif params[:pretty_json]
					output = JSON.pretty_generate(plan)
				else
					output = plan
				end
			}

			output
		end

		def bsig_template
			return {'version' => 1, 'operators' => [], 'id' => Time.now.getutc.to_i, 'goal' => {}, 'goal_operator' => {}}
		end

		def to_sequential_bsig
			bsig = self.bsig_template
			return bsig if @plan.length <= 0

			plan = self.get_sequential_plan
			bsig['operators'] = workflow = plan['workflow']

			(workflow.length-1).downto(1) do |i|
				op = workflow[i]
				prev_op = workflow[i-1]
				prev_op['effect'].each { |k,v| op['condition'][k] = v }
			end
			bsig['goal'], _ = self.bsig_goal_operator(workflow)

			return bsig
		end

		def to_parallel_bsig
			def set_priority_index(operator, operators)
				pi = 1 
				operator['successors'].each { |i| 
					set_priority_index(operators[i], operators)
					pi = operators[i]['pi'] + 1 if pi <= operators[i]['pi']
				}   
				operator['pi'] = pi
			end 

			return nil if @plan.nil?

			bsig = self.bsig_template
			return bsig if @plan.length <= 0

			# generate parallel plan
			plan = self.get_parallel_plan

			# set BSig operators
			bsig['operators'] = operators = plan['workflow']

			# set priority index
			operators.each { |op| set_priority_index(op, operators) if op['predecessors'].length <= 0 }

			# foreach operator
			# - for each operator's predecessors, add its effects to operator's conditions
			# - remove unnecessary data
			operators.each do |op|
				op['predecessors'].each do |pred|
					pred_op = operators[pred]
					pred_op['effect'].each { |k,v| op['condition'][k] = v }
				end
				op.delete('id')
				op.delete('predecessors')
				op.delete('successors')
			end

			# set goals
			bsig['goal'], bsig['goal_operator'] = self.bsig_goal_operator(operators)

			return bsig
		end

		def bsig_goal_operator(workflow)
			goal_op = {}
			goal = {}
			@sas_task.final_state.each do |g|
				variable, value = @parser.variable_name_and_value(g[:id], g[:value])
				# search a supporting operator
				(workflow.length-1).downto(0) do |i|
					if workflow[i]['effect'].has_key?(variable)
						if workflow[i]['effect'][variable] == value
							goal_op[variable] = workflow[i]['name']
							goal[variable] = value
							break
						else
							#Nuri::Util.debug "#{variable}=#{value} is not changing"
							#Nuri::Util.debug value.inspect + ' == ' + workflow[i]['effect'][variable].inspect
						end
					end
				end
			end
			return goal, goal_op
		end

		def get_sequential_plan
			json = { 'type'=>'sequential', 'workflow'=>nil, 'version'=>'1', 'total'=>0 }
			return json if @plan == nil
			json['workflow'] = []
			@plan.each do |line|
				op_name = line[1, line.length-2].split(' ')[0]
				operator = @parser.operators[op_name]
				raise Exception, 'Cannot find operator: ' + op_name if operator == nil
				json['workflow'] << operator.to_sfw
			end
			json['total'] = json['workflow'].length
			return json
		end

		def get_parallel_plan
			json = {'type'=>'parallel', 'workflow'=>nil, 'init'=>nil, 'version'=>'1', 'total'=>0}
			if @plan.nil?
				return json
			elsif @plan.length <= 0
				json['workflow'] = []
				return json
			end
			
			json['workflow'], json['init'], json['total'] = @sas_task.get_partial_order_workflow(@parser)
			return json
		end

		def extract_sas_plan(sas_plan, parser)
			actions = Array.new
			sas_plan.split("\n").each do |sas_operator|
				op_name = sas_operator[1,sas_operator.length-2].split(' ')[0]
				actions << Action.new(parser.operators[op_name])
			end
		end

		def plan_preprocessing(plan)
			return plan if plan.nil? or plan[0,2] != '1:'
			plan1 = ''
			plan.each_line { |line|
				_, line = line.split(':', 2)
				plan1 += "#{line.strip}\n"
			}
			plan1.strip
		end

		def solve_sas(parser, p={})
			return nil if parser.nil?
			
			tmp_dir = "/tmp/nuri_#{(Time.now.to_f * 1000000).to_i}"
			begin
				benchmarks = {}

				benchmarks['compile step 1'] = Benchmark.realtime do
					parser.compile_step_1
				end

				benchmarks['sas_post_processor'] = Benchmark.realtime do
					p[:sas_post_processor].sas_post_processor(parser) if p[:sas_post_processor]
				end

				benchmarks['compile step 2'] = Benchmark.realtime do
					parser.compile_step_2
				end

				while File.exist?(tmp_dir)
					tmp_dir = "/tmp/nuri_#{(rand * 100000).to_i.abs}"
				end
				Dir.mkdir(tmp_dir)

				benchmarks.merge!(parser.benchmarks)

				sas_file = "#{tmp_dir}/problem.sas"
				plan_file = "#{tmp_dir}/out.plan"
				benchmarks['generating sas'] = Benchmark.realtime do
					File.open(sas_file, 'w') do |f|
						f.write parser.sas
						f.flush
					end
				end

				benchmarks['search_time'] = Benchmark.realtime do
					planner = ParallelHeuristic.new(tmp_dir, sas_file, plan_file)
					planner.solve
				end

				File.open("#{tmp_dir}/#{TranslatorBenchmarkFile}", 'w') { |f| f.write(JSON.pretty_generate(benchmarks)) }

				plan = (File.exist?(plan_file) ? File.read(plan_file) : nil)
				#plan = plan_preprocessing(plan)

				if not plan.nil?
					plan = extract_sas_plan(plan, parser)
					sas_task = Sfp::Sas::Task.new(sas_file)
					sas_task.sas_plan = plan

					tmp = []
					goal_op = nil
					plan.each do |op|
						_, name, _ = op.split('-', 3)
						goal_op = op if name == 'goal'
						next if name == 'goal' or name == 'globalop' or name == 'sometime'
						tmp.push(op)
					end
					sas_task.goal_operator_name = goal_op
					plan = tmp

					return plan, sas_task
				end

			rescue Exception => exp
				raise exp
			ensure
				File.delete('plan_numbers_and_cost') if File.exist?('plan_numbers_and_cost')
				if ENV['SFPLANNER_SEARCH_LOG'].to_s.strip.length > 0 and File.exists?("#{tmp_dir}/search.log") then
					FileUtils.cp "#{tmp_dir}/search.log", ENV['SFPLANNER_SEARCH_LOG']
				end
				Kernel.system('rm -rf ' + tmp_dir) if not @debug
			end

			return nil, nil
		end

		def self.path
			os = `uname -s`.downcase.strip
			machine = `uname -m`.downcase.strip
			planner = nil

			if os == 'linux' and machine[0,3] == 'x86'
				planner = File.expand_path("#{File.dirname(__FILE__)}/../../bin/solver/linux-x86")
			elsif os == 'linux' and machine[0,3] == 'arm'
				planner = File.expand_path("#{File.dirname(__FILE__)}/../../bin/solver/linux-arm")
			elsif os == 'macos' or os == 'darwin'
				planner = File.expand_path("#{File.dirname(__FILE__)}/../../bin/solver/macos")
			end

			raise UnsupportedPlatformException, "#{os} is not supported" if planner.nil?
			planner
		end

		# Return the solver parameters based on given heuristic mode.
		# Default value: FF
		def self.parameters(heuristic='ff')
			return case heuristic
				when 'lmcut' then '--search "astar(lmcut())"'
				when 'blind' then '--search "astar(blind())"'
				when 'cg' then '--search "lazy_greedy(cg(cost_type=2))"'
				when 'cea' then '--search "lazy_greedy(cea(cost_type=2))"'
				when 'mad' then '--search "lazy_greedy(mad())"'
				when 'cea2' then ' --heuristic "hCea=cea(cost_type=2)" \
            --search "ehc(hCea, preferred=hCea,preferred_usage=0,cost_type=0)"'
				when 'ff2' then ' --heuristic "hFF=ff(cost_type=1)" \
--search "lazy(alt([single(sum([g(),weight(hFF, 10)])),
                    single(sum([g(),weight(hFF, 10)]),pref_only=true)],
                    boost=2000),
               preferred=hFF,reopen_closed=false,cost_type=1)"'
				when 'fd-autotune-2' then ' \
--heuristic "hCea=cea(cost_type=2)" \
--heuristic "hCg=cg(cost_type=1)" \
--heuristic "hGoalCount=goalcount(cost_type=2)" \
--heuristic "hFF=ff(cost_type=0)" \
--search "lazy(alt([single(sum([weight(g(), 2),weight(hFF, 3)])),
                    single(sum([weight(g(), 2),weight(hFF, 3)]),pref_only=true),
                    single(sum([weight(g(), 2),weight(hCg, 3)])),
                    single(sum([weight(g(), 2),weight(hCg, 3)]),pref_only=true),
                    single(sum([weight(g(), 2),weight(hCea, 3)])),
                    single(sum([weight(g(), 2),weight(hCea, 3)]),pref_only=true),
                    single(sum([weight(g(), 2),weight(hGoalCount, 3)])),
                    single(sum([weight(g(), 2),weight(hGoalCount, 3)]),pref_only=true)],
                   boost=200),
              preferred=[hCea,hGoalCount],reopen_closed=false,cost_type=1)"'
				when 'fd-autotune-1' then ' \
            --heuristic "hFF=ff(cost_type=1)" \
            --heuristic "hCea=cea(cost_type=0)" \
            --heuristic "hCg=cg(cost_type=2)" \
            --heuristic "hGoalCount=goalcount(cost_type=0)" \
            --heuristic "hAdd=add(cost_type=0)" \
      --search "lazy(alt([single(sum([g(),weight(hAdd, 7)])),
                          single(sum([g(),weight(hAdd, 7)]),pref_only=true),
                          single(sum([g(),weight(hCg, 7)])),
                          single(sum([g(),weight(hCg, 7)]),pref_only=true),
                          single(sum([g(),weight(hCea, 7)])),
                          single(sum([g(),weight(hCea, 7)]),pref_only=true),
                          single(sum([g(),weight(hGoalCount, 7)])),
                          single(sum([g(),weight(hGoalCount, 7)]),pref_only=true)],
                          boost=1000),
                     preferred=[hCea,hGoalCount],
                     reopen_closed=false,cost_type=1)"'
				when 'lama' then ' \
	--heuristic "hlm,hff=lm_ff_syn(lm_rhw(reasonable_orders=true,lm_cost_type=2,cost_type=0), admissible=false, optimal=false, cost_type=0)" \
	--search "lazy_greedy([hlm,hff],preferred=[hlm,hff])"'
				when 'lmlazy','lm' then ' \
	--landmarks "lm=lm_rhw(reasonable_orders=true,lm_cost_type=2,cost_type=2)" \
	--heuristic "hlm=lmcount(lm)" \
	--search "lazy_greedy(sum([g(),weight(hlm,10)]),boost=2000,cost_type=2)"'
				when 'lmeager' then ' \
	--landmarks "lm=lm_rhw(reasonable_orders=true,lm_cost_type=2,cost_type=2)" \
	--heuristic "hlm=lmcount(lm)" \
	--search "eager_greedy(sum([g(),weight(hlm,10)]),boost=2000,cost_type=2)"'
				else '--search "lazy_greedy(ff(cost_type=0))"'
			end
		end

		# Return a command to run the planner:
		# - within given working directory "dir"
		# - problem in SAS+ format, available in"sas_file"
		# - solution will be saved in "plan_file"
		def self.getcommand(dir, sas_file, plan_file, heuristic='ff', debug=false, timeout=nil)
			planner = Sfp::Planner.path
			params = Sfp::Planner.parameters(heuristic)
			timeout = Sfp::Planner::Config.timeout if timeout.nil?

			case `uname -s `.downcase.strip
				when 'linux'
					then "cd #{dir} && \
					      ulimit -Sv #{Sfp::Planner::Config.max_memory} && \
					      #{planner}/preprocess < #{sas_file} 2>/dev/null 1>/dev/null && \
					      if [ -f 'output' ]; then \
					      timeout #{timeout} nice #{planner}/downward #{params} \
					      --plan-file #{plan_file} < output 1>>search.log 2>>search.log; fi"
				when 'macos', 'darwin'
					then "cd #{dir} && \
					      ulimit -Sv #{Sfp::Planner::Config.max_memory} && \
					      #{planner}/preprocess < #{sas_file} 1>/dev/null 2>/dev/null && \
					      if [ -f 'output' ]; then \
						   nice #{planner}/downward #{params} \
					      --plan-file #{plan_file} < output 1>>search.log 2>>search.log; fi"
				else nil
			end
		end

		def self.get_search_command(dir, plan_file, heuristic, timeout=nil, single=true)
			planner = Sfp::Planner.path
			params = Sfp::Planner.parameters(heuristic)
			timeout = Sfp::Planner::Config.timeout if timeout.nil?
			max_memory = Sfp::Planner::Config.max_memory
			logfile = (single ? "search.log" : "search.log." + heuristic)
			platform = `uname -s`.downcase.strip

			limit = ""
			if not ENV['SFPLANNER_NO_LIMIT']
				limit = case platform
				when 'linux'
					"ulimit -Sv #{max_memory} && timeout #{timeout}"
				when 'macos', 'darwin'
					"ulimit -Sv #{max_memory} &&"
				end
			end

			case platform
			when 'linux'
				"#{limit} nice #{planner}/downward #{params} \
				 --plan-file #{plan_file} < output 1>>#{logfile} 2>>#{logfile}"
			when 'macos', 'darwin'
				"#{limit} nice #{planner}/downward #{params} \
				 --plan-file #{plan_file} < output 1>>#{logfile} 2>>#{logfile}"
			else
				raise Exception, "unsupported platform: #{platform}"
			end
		end

		def self.get_preprocess_command(dir, sas_file)
			case `uname -s`.downcase.strip
			when 'linux', 'macos', 'darwin'
				"cd #{dir} && #{Sfp::Planner.path}/preprocess < #{sas_file} 2>/dev/null 1>/dev/null"
			else
				"exit 1"
			end
		end

		# Combination between two heuristic to obtain a suboptimal plan.
		# 1) solve the problem with CG/CEA/FF, that will produce (usually) a non-optimal plan
		# 2) remove actions which are not selected by previous step
		# 3) solve the problem with LMCUT using A*-search to obtain a sub-optimal plan
		class MixedHeuristic
			attr_reader :heuristics_order

			def initialize(dir, sas_file, plan_file, continue=false, optimize=true)
				@dir = dir
				@sas_file = sas_file
				@plan_file = plan_file
				@heuristics_order = ['ff2', 'cea2', 'fd-autotune1', 'fd-autotune2']
				@heuristics_order = ENV['SFPLANNER_MIXED_HEURISTICS'].split(',') if ENV['SFPLANNER_MIXED_HEURISTICS']
				@continue = continue
				@continue = true if ENV['SFPLANNER_MIXED_CONTINUE']
				@optimize = optimize
			end

			def solve2
				if not File.exist?(@plan_file)
 					#fd-autotune-1
					planner = Sfp::Planner.getcommand(@dir, @sas_file, @plan_file, 'fd-autotune-1')
					Kernel.system(planner)
				end
				if not File.exist?(@plan_file)
 					#fd-autotune-2
					planner = Sfp::Planner.getcommand(@dir, @sas_file, @plan_file, 'fd-autotune-2')
					Kernel.system(planner)
				end
				if not File.exists?(@plan_file)
					# solve with cea2 (EHC+CEA: see fd-autotune-2)
					planner = Sfp::Planner.getcommand(@dir, @sas_file, @plan_file, 'cea2')
					Kernel.system(planner)
				end
				if not File.exists?(@plan_file)
					# solve with ff2 (FF with boost: see fd-autotune-1)
					planner = Sfp::Planner.getcommand(@dir, @sas_file, @plan_file, 'ff2')
					Kernel.system(planner)
				end

				# final try: using an admissible heuristic
				#if not File.exist?(@plan_file)
				#	use_admissible = true
				#	planner = Sfp::Planner.getcommand(@dir, @sas_file, @plan_file, 'lmcut', false, '20m')
				#	Kernel.system(planner)
				#end

				return false if not File.exist?(@plan_file)
				optimize_plan if @optimize

				true
			end

			def solve
				total = 0
				@heuristics_order.each do |heuristic|
					command = Sfp::Planner.getcommand(@dir, @sas_file, @plan_file, heuristic)
					Kernel.system(command)
					if File.exist?(@plan_file)
						total += 1
						File.rename(@plan_file, "#{@plan_file}.sol.#{total}")
						break if not @continue
					end
				end

				return false if total <= 0

				best_length = 1000000
				1.upto(total) do |i|
					filepath = "#{@plan_file}.sol.#{i}"
					plan_length = File.read(filepath).split("\n").length
					if plan_length < best_length
						File.delete(@plan_file) if File.exist?(@plan_file)
						FileUtils.copy(filepath, @plan_file)
					end
				end

				optimize_plan if @optimize

				true
			end

			def optimize_plan
				# 2) remove unselected operators
				new_sas = @sas_file + '.2'
				new_plan = @plan_file + '.2'
				self.filter_operators(@sas_file, @plan_file, new_sas)

				# 3) generate the final plan with LMCUT
				lmcut = Sfp::Planner.getcommand(@dir, new_sas, new_plan, 'lmcut')
				Kernel.system(lmcut)

				# 4) LMCUT cannot find the sub-optimized plan
				if File.exist?(new_plan)
					File.delete(@plan_file)
					File.rename(new_plan, @plan_file)
				end
			end

			def filter_operators(sas, plan, new_sas)
				# generate the selected actions
				selected = []
				File.read(plan).each_line do |line|
					line.strip!
					line = line[1, line.length-2]
					selected << line.split(' ', 2)[0]
					#'$.' + line[1, line.length-2].split(' ', 2)[0].split('$.')[1]
				end

				# remove unselected operators
				output = ""
				operator = nil
				id = nil
				total_op = false
				counter = 0
				File.read(sas).each_line do |line|
					if line =~ /^end_goal/
						total_op = true
					elsif total_op
						output += "__TOTAL_OPERATOR__\n"
						total_op = false
						next
					end

					if line =~ /^begin_operator/
						operator = ""
						id = nil
					elsif line =~ /^end_operator/
						if not selected.index(id).nil?
							output += "begin_operator\n#{operator}end_operator\n"
							counter += 1
						end
						operator = nil
						id = nil
					elsif operator.nil?
						output += line
					else
						id = line.split(' ', 2)[0] if id.nil?
						operator += line
					end
				end

				# replace total operator
				output.sub!(/__TOTAL_OPERATOR__/, counter.to_s)

				# save filtered problem
				File.open(new_sas, 'w') { |f| f.write(output) }
			end
		end


		class ParallelHeuristic < MixedHeuristic
			def initialize(dir, sas_file, plan_file, optimize=false)
				@dir = dir
				@sas_file = sas_file
				@plan_file = plan_file
				if ENV['SFPLANNER_HEURISTICS']
					@heuristics = ENV['SFPLANNER_HEURISTICS'].split(',')
				else
					@heuristics = ['lama'] # ['ff2', 'cea2', 'fd-autotune-1', 'fd-autotune-2']
				end
				if ENV['SFPLANNER_OPTIMIZE']
					@optimize = case ENV['SFPLANNER_OPTIMIZE']
					when '1', 'true'
						true
					else
						false
					end
				else
					@optimize = optimize
				end
				@timeout = (ENV['SFPLANNER_TIMEOUT'] ? ENV['SFPLANNER_TIMEOUT'].to_i : Sfp::Planner::Config.timeout)
			end

			def pids(dir='')
				`ps ax | grep -v grep | grep downward | grep sfplanner | grep '#{dir}' | awk '{print $1" "}'`.to_s.strip.split("\n")
			end

			def solve
				def kill(dir='')
					system "kill -9 #{pids(dir).join(' ')} 1>/dev/null 2>/dev/null"
				end

				### run preprocessing
				return false if not do_preprocess

				['HUP', 'KILL', 'INT'].each { |name,id|
					dir = @dir
					Signal.trap(name) { kill(dir) }
				}

				### save current working dir
				home = Dir.pwd

				### change to temporary working dir
				Dir.chdir @dir

				### run a thread for each heuristic
				files = []
				@heuristics.each do |heuristic|
					plan_file = @plan_file + '.' + heuristic
					cmd = Sfp::Planner.get_search_command(@dir, plan_file, heuristic, @timeout, (@heuristics.length == 1))
					pid = Process.spawn cmd
					Process.detach pid
					files << plan_file
				end

				loop do
					list = pids(@dir)
					break if list.length <= 0
					finished = files.select { |f| File.exist?(f) }
					break if finished.length > 0
					sleep 0.2
				end

				kill(@dir)

				### select best plan
				selected = nil
				length = -1
				files.each do |file|
					if File.exist?(file)
						len = File.read(file).split("\n").length
						if length < 0 or len < length
							length = len
							selected = file
						end
					end
				end

				if not selected.nil?
					FileUtils.copy(selected, @plan_file)
					optimize_plan if @optimize

					Dir.chdir home
					true
				else
					Dir.chdir home
					false
				end

			ensure
				kill(@dir)
			end

			def do_preprocess
				(!!system(Sfp::Planner.get_preprocess_command(@dir, @sas_file)) &&
				 File.exist?(@dir + '/output'))
			end
		end


		class Action
			attr_accessor :operator, :predecessor

			def initialize(operator)
				@operator = operator
				@predecessor = Array.new
			end
		end
	
		class UnsupportedPlatformException < Exception
		end
	end
end
