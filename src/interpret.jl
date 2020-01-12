# entry point
# -----------

# function profile_file(filename::AbstractString; mod::Module = Main)
#   isfile(filename) || error("No such file exists: $filename")
#   filetext = read(filename, String)
#   profile_text(filetext; filename = filename, mod = Main)
# end
# function profile_text(text::String; filename::AbstractString = "none", mod::Module = Main)
#   exs = Base.parse_input_line(text; filename = filename)
#   for i = 2:2:length(exs.args)
#     frame = prepare_thunk(mod, exs.args[i])
#     evaluate_or_profile!(frame, true)
#   end
# end

function evaluate_or_profile!(frame::Frame)
  while (pc = step_code!(frame)) !== nothing end
  return rettyp(frame)
end

# recursive call
# --------------

function step_code!(frame)
  frame.pc > nstmts(frame) && return nothing
  return pc = step_code!(frame, pc_stmt(frame))
end
function step_code!(frame, @nospecialize(stmt))
  @assert is_leaf(frame)
  rhs_type = profile_and_get_rhs_type!(frame, stmt)
  assign_rhs_type!(frame, stmt, rhs_type)
  return frame.pc += 1
end

function profile_and_get_rhs_type!(frame, @nospecialize(stmt))
  error("unimplemented type statement: $stmt")
end
profile_and_get_rhs_type!(frame, ::Nothing) = Nothing
# ignore goto statement and just proceed to profile the next statement
profile_and_get_rhs_type!(frame, gn::GotoNode) = Any
# TODO:
# use updated (i.e. profiled) types instead of inferred ones for Pi, Phi nodes
# - Pi node check: pi.typ == frame.ssavaluetypes[pi.val]
# - Phi node check: Core.tmerge(lookup_type.(phi.values)) == Core.tmerge(getindex.(frame.ssavaluetypes, phi.values))
profile_and_get_rhs_type!(frame, pi::PiNode) = frame.src.ssavaluetypes[frame.pc]
profile_and_get_rhs_type!(frame, phi::PhiNode) = frame.src.ssavaluetypes[frame.pc]
profile_and_get_rhs_type!(frame, gr::GlobalRef) = lookup_type(frame, gr)
function profile_and_get_rhs_type!(frame, ex::Expr)
  head = ex.head
  if head === :call
    return profile_call!(frame, ex)
  elseif head === :invoke
    mi = ex.args[1]::MethodInstance
    slottyps = collect_call_argtypes(frame, ex)
    newframe = Frame(mi, slottyps, frame)
    frame.callee = FrameChain(lineinfonode(frame), newframe)
    rettyp = evaluate_or_profile!(newframe)
    frame.callee = nothing
    return rettyp
  # :new and :foreigncall are supposed to be statically computed, let's just trust the inference
  elseif head === :new
    typ = lookup_type(frame, ex.args[1])
    return typ.parameters[1]::Type
  elseif head === :foreigncall
    typ = lookup_type(frame, ex.args[2]) # XXX: maybe Ref{T} case will break this ?
    return typ.parameters[1]::Type
  elseif head === :gotoifnot
    return profile_gotoifnot!(frame, ex)
  elseif (
    head === :meta ||
    head === (@static VERSION >= v"1.2.0-DEV.462" ? :loopinfo : :simdloop) ||
    head === :gc_preserve_begin ||
    head === :gc_preserve_end
  )
    return Any
  elseif head === :unreachable
    # basically this is a sign of an error, but hopefully we profiled all of them
    # up to here, so let's just ignore this
    return Unknown
  elseif head === :return
    retex = ex.args[1]
    rettyp = lookup_type(frame, retex)
    return update_rettyp!(frame, rettyp)
  else
    error("unimplmented expression type: $ex")
  end
end

# lookups
# -------

lookup_type(frame::Frame, @nospecialize(x)) = typeof′(x)
lookup_type(frame::Frame, ssav::SSAValue) = frame.ssavaluetypes[ssav.id]
lookup_type(frame::Frame, slot::SlotNumber) = frame.slottypes[slot.id]
function lookup_type(frame::Frame, gr::GlobalRef)
  if isdefined(gr.mod, gr.name)
    typeof′(getfield(gr.mod, gr.name))
  else
    # TODO: error report
    return Unknown
  end
end
lookup_type(frame::Frame, qn::QuoteNode) = typeof′(qn.value)
function lookup_type(frame::Frame, ex::Expr)
  head = ex.head
  if head === :static_parameter
    return frame.sparams[ex.args[1]]
  elseif head === :boundscheck
    return Bool
  # TODO: handle exceptions somehow
  elseif head === :enter || head === :leave || head === :pop_exception
    return Any
  end
  error("unimplmented expression lookup: $ex")
end

# assignment and return
# ---------------------

assign_rhs_type!(frame, stmt, rhs_type) = frame.ssavaluetypes[frame.pc] = rhs_type

function update_rettyp!(frame, rettyp)
  @return_if_unknown! frame.rettyp
  # let's ignore previously profiled types once we profile Unknown
  rettyp == Unknown && return frame.rettyp = Unknown
  return frame.rettyp = tmerge(frame.rettyp, rettyp)
end
