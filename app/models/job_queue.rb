# frozen_string_literal: true
# make jobs with the same queue run in serial and track their status
class JobQueue
  include Singleton

  # Whether or not execution is enabled. This allows completely disabling job
  # execution for testing purposes and when restarting samson.
  class << self
    attr_accessor :enabled
  end

  class << self
    delegate :executing, :executing?, :queued?, :dequeue, :find_by_id, :perform_later, :debug, :clear, :wait, :kill,
      to: :instance
  end

  def executing
    @executing.values
  end

  def executing?(id)
    executing.detect { |je| je.id == id }
  end

  def queued?(id)
    @queue.values.detect { |jes| jes.detect { |je| return je if je.id == id } }
  end

  def dequeue(id)
    !!@queue.values.detect { |jes| jes.reject! { |je| je.id == id } }
  end

  def find_by_id(id)
    @lock.synchronize { executing?(id) || queued?(id) }
  end

  # when no queue is given jobs run in parallel (each in their own queue) and start instantly
  # when samson is restarting we do not start jobs, but leave them pending
  def perform_later(job_execution, queue: nil)
    queue ||= job_execution.id

    if JobQueue.enabled
      @lock.synchronize do
        if hit_max_concurrent_jobs?
          puts 'mpc: Hit max concurrent jobs'
        else
          puts 'mpc: Didnt hit max concurrent jobs'
        end
        if @executing[queue]
          @queue[queue] << job_execution
          false
        else
          @executing[queue] = job_execution
          perform_job(job_execution, queue)
          true
        end
      end
    end

    instrument
  end

  def debug
    [@executing, @queue]
  end

  def clear
    raise unless Rails.env.test?
    @threads.each_value(&:kill) # cleans itself ... but we clear for good measure
    @threads.each_value(&:join)
    @threads.clear
    @executing.clear
    @queue.clear
  end

  def wait(id, timeout = nil)
    @threads[id]&.join(timeout)
  end

  def kill(id)
    @threads[id]&.kill
  end

  private

  def initialize
    @queue = Hash.new { |h, q| h[q] = [] }
    @lock = Mutex.new
    @executing = {}
    @threads = {}
  end

  # assign the thread first so we do not get into a state where the execution is findable but has no thread
  # so our mutex guarantees that all jobs/queues are in a valid state
  # ideally the job_execution should not know about it's thread and we would call cancel/wait on the job-queue instead
  def perform_job(job_execution, queue)
    @threads[job_execution.id] = Thread.new do
      begin
        job_execution.perform
      ensure
        delete_and_enqueue_next(job_execution, queue)
        @threads.delete(job_execution.id)
      end
    end
  end

  def delete_and_enqueue_next(job_execution, queue)
    @lock.synchronize do
      previous = @executing.delete(queue)
      unless job_execution == previous
        raise "Unexpected executing job found in queue #{queue}: expected #{job_execution&.id} got #{previous&.id}"
      end

      if JobQueue.enabled && (next_execution = @queue[queue].shift)
        @executing[queue] = next_execution
        perform_job(next_execution, queue)
      end

      @queue.delete(queue) if @queue[queue].empty? # save memory, and time when iterating all queues
    end

    instrument
  end

  def hit_max_concurrent_jobs?
    configured = ENV['MAX_CONCURRENT_JOBS'].to_i
    if !configured
      return false
    end

    running = @executing.length
    @queue.each do |k, v|
      running += v.length
    end

    return running >= configured
  end

  def instrument
    ActiveSupport::Notifications.instrument(
      "job_queue.samson",
      threads: @executing.length,
      queued: @queue.values.sum(&:count)
    )
  end
end
