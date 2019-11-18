from locust import HttpLocust, TaskSet, task

class NetCoreCounterUser(TaskSet):
  @task
  def leer(self):
      self.client.get("/api/v1/Counter/leer")

class ElbWarmer(HttpLocust):
  task_set = NetCoreCounterUser
  min_wait = 1000
  max_wait = 3000
