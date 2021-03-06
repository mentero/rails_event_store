require 'activerecord-import'

module RailsEventStoreActiveRecord
  class EventRepository

    POSITION_SHIFT = 1

    def initialize(mapper: RubyEventStore::Mappers::Default.new)
      verify_correct_schema_present
      @mapper      = mapper
      @repo_reader = EventRepositoryReader.new(mapper)
    end

    def append_to_stream(events, stream_name, expected_version)
      add_to_stream(normalize_to_array(events), stream_name, expected_version, true) do |event|
        build_event_record(event).save!
        event.event_id
      end
    end

    def link_to_stream(event_ids, stream_name, expected_version)
      (normalize_to_array(event_ids) - Event.where(id: event_ids).pluck(:id)).each do |id|
        raise RubyEventStore::EventNotFound.new(id)
      end
      add_to_stream(normalize_to_array(event_ids), stream_name, expected_version, nil) do |event_id|
        event_id
      end
    end

    def delete_stream(stream_name)
      EventInStream.where(stream: stream_name).delete_all
    end

    def has_event?(event_id)
      @repo_reader.has_event?(event_id)
    end

    def last_stream_event(stream_name)
      @repo_reader.last_stream_event(stream_name)
    end

    def read_events_forward(stream_name, after_event_id, count)
      @repo_reader.read_events_forward(stream_name, after_event_id, count)
    end

    def read_events_backward(stream_name, before_event_id, count)
      @repo_reader.read_events_backward(stream_name, before_event_id, count)
    end

    def read_stream_events_forward(stream_name)
      @repo_reader.read_stream_events_forward(stream_name)
    end

    def read_stream_events_backward(stream_name)
      @repo_reader.read_stream_events_backward(stream_name)
    end

    def read_all_streams_forward(after_event_id, count)
      @repo_reader.read_all_streams_forward(after_event_id, count)
    end

    def read_all_streams_backward(before_event_id, count)
      @repo_reader.read_all_streams_backward(before_event_id, count)
    end

    def read_event(event_id)
      @repo_reader.read_event(event_id)
    end

    def get_all_streams
      @repo_reader.get_all_streams
    end

    private

    def add_to_stream(collection, stream_name, expected_version, include_global, &to_event_id)
      raise RubyEventStore::InvalidExpectedVersion if stream_name.eql?(RubyEventStore::GLOBAL_STREAM) && !expected_version.equal?(:any)

      expected_version = normalize_expected_version(expected_version, stream_name)

      ActiveRecord::Base.transaction(requires_new: true) do
        in_stream = collection.flat_map.with_index do |element, index|
          position = compute_position(expected_version, index)
          event_id = to_event_id.call(element)
          collection = []
          collection.unshift({
            stream: RubyEventStore::GLOBAL_STREAM,
            position: nil,
            event_id: event_id
          }) if include_global
          collection.unshift({
            stream:   stream_name,
            position: position,
            event_id: event_id
          }) unless stream_name.eql?(RubyEventStore::GLOBAL_STREAM)
          collection
        end
        EventInStream.import(in_stream)
      end
      self
    rescue ActiveRecord::RecordNotUnique => e
      raise_error(e)
    end

    def raise_error(e)
      if detect_index_violated(e.message)
        raise RubyEventStore::EventDuplicatedInStream
      end
      raise RubyEventStore::WrongExpectedEventVersion
    end

    def compute_position(expected_version, index)
      unless expected_version.equal?(:any)
        expected_version + index + POSITION_SHIFT
      end
    end

    def normalize_expected_version(expected_version, stream_name)
      case expected_version
        when Integer, :any
          expected_version
        when :none
          -1
        when :auto
          eis = EventInStream.where(stream: stream_name).order("position DESC").first
          (eis && eis.position) || -1
        else
          raise RubyEventStore::InvalidExpectedVersion
      end
    end

    def detect_index_violated(message)
      IndexViolationDetector.new.detect(message)
    end

    def build_event_record(event)
      serialized_record = @mapper.event_to_serialized_record(event)
      Event.new(
        id:         serialized_record.event_id,
        data:       serialized_record.data,
        metadata:   serialized_record.metadata,
        event_type: serialized_record.event_type
      )
    end

    def normalize_to_array(events)
      return events if events.is_a?(Enumerable)
      [events]
    end

    def verify_correct_schema_present
      CorrectSchemaVerifier.new.verify
    end
  end

end
